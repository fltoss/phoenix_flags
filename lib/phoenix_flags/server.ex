defmodule PhoenixFlags.Server do
  @moduledoc """
  The process that owns an instance's cache, and the API a config module
  delegates to.

  Each `use PhoenixFlags` module starts its own Server, named after the
  module. Reads go straight to `:persistent_term` and never call it; cached
  writes go through it, so a write and a cache reload cannot interleave.
  """
  use GenServer

  alias PhoenixFlags.Audit
  alias PhoenixFlags.Cache
  alias PhoenixFlags.Config
  alias PhoenixFlags.Declarations
  alias PhoenixFlags.Reader
  alias PhoenixFlags.Seed
  alias PhoenixFlags.Store
  alias PhoenixFlags.Targeting
  alias PhoenixFlags.Values

  require Logger

  @doc false
  def start_link(%Config{} = config) do
    GenServer.start_link(__MODULE__, config, name: config.name)
  end

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Returns the cached value for a config key.

  Targeting rules are consulted first: if one matches the request context, its
  value wins over the stored value. See `PhoenixFlags.Target`.

  When `cache_enabled: false`, checks the process dictionary first
  (for test overrides), then targeting rules, then falls back to a direct DB read.

  ## Options

    * `:context` — attributes for targeting rules, overriding the process-scoped
      `PhoenixFlags.Context`. Given neither, targeting is skipped entirely.

  Raises for a `:variant` flag: it holds a split rather than a single value, and
  returning the struct would leak it into application code. Use `variant/4`.
  """
  def get(instance, key, default \\ nil, opts \\ []), do: Reader.get(instance, key, default, opts)

  @doc """
  Returns the variant assigned to `identity` for a `:variant` flag.

  Deterministic for a given identity, split and seed — see `PhoenixFlags.Variant`.
  Cached, it is a `:persistent_term` read, a hash and a short list walk; the
  split is parsed once when the cache loads.

  ## Options

    * `:default` — returned when the flag does not exist, is not a `:variant`
      flag, the instance is not running, or the identity is unusable. Defaults to
      `nil`.
    * `:telemetry` — when `true`, emits `[:phoenix_flags, :variant, :assigned]`
      with `%{flag: key, identity: identity, variant: variant, instance: instance}`
      as metadata, so exposures can be piped into your own analytics. Off by
      default to keep the read path free.
    * `:context` — attributes for targeting rules, overriding the process-scoped
      context. A matching rule pins the caller to its variant, ahead of the split.
    * `:now` — current time in milliseconds, for testing TTL rollover.
  """
  def variant(instance, key, identity, opts \\ []),
    do: Reader.variant(instance, key, identity, opts)

  @doc """
  Returns all config entries grouped by category.
  """
  def all_grouped(instance), do: Reader.all_grouped(instance)

  @doc """
  Returns the targeting rules for a flag, in evaluation order.
  """
  def targets(instance, key) do
    case Cache.config(instance) do
      {:ok, config} -> Targeting.list(config, key)
      :error -> []
    end
  end

  @doc """
  Adds a targeting rule to a flag.

  `attrs` takes `:value` and `:conditions`, and optionally `:position`:

      put_target(MyApp.SystemConfig, "enable_benefits",
        conditions: [[attribute: :company_id, operator: :in, values: [123]]],
        value: "true"
      )

  The value must be valid for the flag's type, checked with the same rules a
  dashboard save goes through. `:secret` flags cannot be targeted — a rule value
  would sit in the targets table as plaintext, defeating the encryptor.

  Pass `actor:` in `opts` to name who added it in the audit log.
  """
  def put_target(instance, key, attrs, opts \\ []) do
    config = Cache.config!(instance)

    with {:ok, target} <- Targeting.insert(config, key, attrs) do
      Audit.record(config, key, nil, "rule: " <> Targeting.describe(target), "rule", opts[:actor])
      refresh_rules(config)
      {:ok, target}
    end
  end

  @doc """
  Deletes a targeting rule by id. Its conditions go with it.

  Returns `{:error, :not_found}` for an unknown id and `{:error, :unavailable}`
  when the database cannot be reached. Pass `actor:` in `opts` for the audit log.
  """
  def delete_target(instance, target_id, opts \\ []) do
    config = Cache.config!(instance)

    with {:ok, deleted} <- Targeting.delete(config, target_id) do
      Audit.record(
        config,
        deleted.key,
        "rule: " <> Targeting.describe(deleted),
        nil,
        "rule",
        opts[:actor]
      )

      refresh_rules(config)
      {:ok, deleted}
    end
  end

  @doc """
  Updates a config entry and refreshes the cache.

  When `cache_enabled: false`, runs in the caller's process for Ecto sandbox compatibility.

  Accepts an optional `:timeout` (in milliseconds, default `5000`). A write that
  takes longer returns `{:error, :timeout}` rather than exiting, and may still
  land — read the value back to learn which.
  """
  def update_entry(instance, key, attrs, opts \\ [])

  # `key` is caller-supplied and the column is a string, so a non-binary key
  # would raise Ecto.Query.CastError from the lookup.
  def update_entry(_instance, key, _attrs, _opts) when not is_binary(key),
    do: {:error, :not_found}

  def update_entry(instance, key, attrs, opts) do
    config = Cache.config!(instance)
    actor = Keyword.get(opts, :actor)

    if config.cache_enabled do
      call_update(instance, key, attrs, actor, Keyword.get(opts, :timeout, 5_000))
    else
      # Uncached writes run in the caller, bypassing the Server and its Ecto
      # sandbox ownership. No rescue, by design: with no process to keep alive,
      # a test that lost its sandbox connection wants the exception.
      with {:ok, entry} <- Store.fetch(config, key) do
        Store.update(config, entry, attrs, actor)
      end
    end
  end

  @doc """
  Returns all audit log entries, newest first.

  Raises `PhoenixFlags.Error` unless the instance is configured with `audit: true`.
  """
  def audit_log(instance), do: instance |> Cache.config!() |> Audit.enabled!() |> Audit.list()

  @doc """
  Returns audit log entries for a specific key, newest first.

  Raises `PhoenixFlags.Error` unless the instance is configured with `audit: true`.
  """
  def audit_log(instance, key),
    do: instance |> Cache.config!() |> Audit.enabled!() |> Audit.list(key)

  @doc """
  Returns the config for the given instance. Used by the UI to resolve actor.
  """
  def config(instance), do: Cache.config!(instance)

  @doc """
  Deletes stored flags the config module no longer declares, with their
  targeting rules, and returns the deleted keys.

  Startup never deletes a row: during a rolling deploy the old and new releases
  disagree about which flags exist. Run this once every node runs code that no
  longer declares the flags.
  """
  def prune_undeclared(instance) do
    config = Cache.config!(instance)
    keys = Seed.prune(config)
    if keys != [], do: reload_everywhere(config)
    keys
  end

  # A caller waiting on a busy Server must not die with it: the dashboard calling
  # here is a LiveView, and an exit takes the page down over a write that may
  # well have landed. The late reply is dropped, as GenServer.call aliases it.
  defp call_update(instance, key, attrs, actor, timeout) do
    GenServer.call(instance, {:update, key, attrs, actor}, timeout)
  catch
    :exit, {:timeout, _} ->
      Logger.warning("PhoenixFlags: update of #{inspect(key)} timed out after #{timeout}ms")
      {:error, :timeout}
  end

  # ============================================================================
  # GenServer
  # ============================================================================

  @impl true
  def init(%Config{} = config) do
    Process.flag(:trap_exit, true)
    validate_encryptor!(config)
    claim_repo!(config)
    Cache.put_config(config)
    Cache.put_order(config.name, Declarations.order(config.name))
    if Seed.sync(config), do: notify_peers(config)
    load_cache(config)
    schedule_refresh(config)
    {:ok, config}
  end

  @impl true
  def handle_call({:update, key, attrs, actor}, _from, %Config{} = config) do
    {:reply, update(config, key, attrs, actor), config}
  end

  # Rules are reloaded here rather than in the caller, so a rule change and a
  # periodic reload cannot overwrite each other with an older read.
  def handle_call(:reload_rules, _from, %Config{} = config) do
    store_targets(config, Cache.entries(config.name))
    notify_peers(config)
    {:reply, :ok, config}
  end

  @impl true
  def handle_info(:reload, %Config{} = config) do
    try_load_cache(config, "failed to reload cache")
    {:noreply, config}
  end

  def handle_info(:refresh, %Config{} = config) do
    try_load_cache(config, "periodic cache refresh failed")
    schedule_refresh(config)
    {:noreply, config}
  end

  def handle_info(_message, config), do: {:noreply, config}

  # A crash report prints the message being handled and the mailbox, and an
  # {:update, ...} carries a secret's plaintext. GenServer only declares the
  # callback from Elixir 1.17; OTP calls it either way.
  if Version.match?(System.version(), ">= 1.17.0") do
    @impl true
    def format_status(status), do: redact_status(status)
  else
    def format_status(status), do: redact_status(status)
  end

  @impl true
  def terminate(_reason, %Config{} = config) do
    # Leave the cache, config, order, and targets keys intact so that get/3 and
    # all_grouped/0 can keep serving (possibly stale) values during a
    # restart. init/1 overwrites them with fresh data. Only the repo
    # claim is released — it guards concurrently *running* instances.
    release_repo_claim(config)
  rescue
    error ->
      Logger.debug("PhoenixFlags: terminate cleanup failed: #{inspect(error)}")
      :ok
  end

  # A DB error (connection loss, constraint violation, ...) must not crash
  # the Server: that would erase nothing but still restart the process and
  # re-seed. Convert exceptions into an error changeset the caller (and the
  # dashboard form) can render.
  defp update(%Config{} = config, key, attrs, actor) do
    with {:ok, entry} <- Store.fetch(config, key),
         {:ok, updated} <- Store.update(config, entry, attrs, actor) do
      patch_cache(config, updated)
      notify_peers(config)
      {:ok, updated}
    end
  rescue
    error ->
      # The exception module only: an encryptor raising FunctionClauseError
      # carries the plaintext in its arguments.
      Logger.error("PhoenixFlags: failed to update #{inspect(key)}: #{inspect(error.__struct__)}")

      changeset =
        %PhoenixFlags.Entry{key: key}
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.add_error(:value, "could not be saved (database error)")
        |> Map.put(:action, :update)

      {:error, changeset}
  end

  defp patch_cache(config, updated) do
    Cache.patch_entry(config.name, updated, Values.decode(updated, config))
  rescue
    error -> Logger.error("PhoenixFlags: failed to update cache after write: #{inspect(error)}")
  end

  defp load_cache(%Config{} = config) do
    entries = Store.all(config)

    Cache.put_entries(
      config.name,
      Map.new(entries, &{&1.key, Values.decode(&1, config)}),
      entries
    )

    store_targets(config, entries)
  end

  defp try_load_cache(config, failure) do
    load_cache(config)
  rescue
    error -> Logger.error("PhoenixFlags: #{failure}: #{inspect(error)}")
  end

  defp store_targets(config, entries) do
    Cache.put_targets(config.name, Targeting.load(config, entries))
  rescue
    error -> Logger.warning("PhoenixFlags: failed to load targeting rules: #{inspect(error)}")
  end

  # Uncached there is nothing to refresh: reads take rules from the table.
  # A failed call is healed by the periodic refresh, so it is logged, not raised.
  defp refresh_rules(%Config{cache_enabled: true, name: name}) do
    GenServer.call(name, :reload_rules)
  catch
    :exit, reason -> Logger.warning("PhoenixFlags: could not reload rules: #{inspect(reason)}")
  end

  defp refresh_rules(%Config{}), do: :ok

  defp reload_everywhere(%Config{cache_enabled: true, name: name} = config) do
    send(name, :reload)
    notify_peers(config)
  end

  defp reload_everywhere(%Config{}), do: :ok

  defp notify_peers(%Config{} = config) do
    for node <- Node.list() do
      case :erlang.send({config.name, node}, :reload, [:noconnect, :nosuspend]) do
        :ok ->
          :ok

        :noconnect ->
          Logger.warning("PhoenixFlags: peer #{node} is unreachable")

        :nosuspend ->
          Logger.warning("PhoenixFlags: peer #{node} send buffer full, skipping notification")
      end
    end
  end

  defp schedule_refresh(%Config{cache_enabled: true, refresh_interval: interval})
       when is_integer(interval) and interval > 0 do
    # Jitter avoids synchronised reload stampedes across cluster nodes.
    jitter = :rand.uniform(max(div(interval, 10), 1))
    Process.send_after(self(), :refresh, interval + jitter)
    :ok
  end

  defp schedule_refresh(%Config{}), do: :ok

  defp validate_encryptor!(%Config{encryptor: nil, name: name}) do
    if Declarations.any_secret?(name) do
      raise PhoenixFlags.Error,
            "#{inspect(name)} declares :secret flags but no :encryptor is configured. " <>
              "Add `encryptor: MyApp.Encryptor` to your `use PhoenixFlags` options; the module " <>
              "must export `encrypt/1` and `decrypt/1`."
    end
  end

  defp validate_encryptor!(%Config{encryptor: encryptor, name: name}) do
    Code.ensure_loaded(encryptor)

    unless function_exported?(encryptor, :encrypt, 1) and
             function_exported?(encryptor, :decrypt, 1) do
      raise PhoenixFlags.Error,
            "encryptor #{inspect(encryptor)} for #{inspect(name)} must export encrypt/1 and decrypt/1"
    end
  end

  # Two config modules with *different* flag declarations sharing one repo
  # would fight over the same rows: each resets the metadata the other declares,
  # and prune_undeclared/1 on one deletes the other's flags. Same declarations
  # are allowed — that's the normal multi-node cluster scenario exercised with
  # two local instances in tests. The claim is per node: it guards against a
  # configuration mistake, not against another release in the cluster.
  defp claim_repo!(%Config{repo: repo, name: name}) do
    keys = Declarations.keys(name)
    claim = %{name: name, keys: keys}

    case Cache.repo_claim(repo) do
      nil ->
        Cache.put_repo_claim(repo, claim)

      %{name: ^name} ->
        Cache.put_repo_claim(repo, claim)

      %{name: other, keys: other_keys} ->
        cond do
          not is_pid(Process.whereis(other)) ->
            Cache.put_repo_claim(repo, claim)

          MapSet.equal?(keys, other_keys) ->
            :ok

          true ->
            raise PhoenixFlags.Error,
                  "#{inspect(name)} and #{inspect(other)} both use repo #{inspect(repo)} " <>
                    "but declare different flags. PhoenixFlags stores all flags in one " <>
                    "system_flags table, so two config modules on the same repo would " <>
                    "overwrite each other's flags. Use one config module per repo."
        end
    end
  end

  defp release_repo_claim(%Config{repo: repo, name: name}) do
    case Cache.repo_claim(repo) do
      %{name: ^name} -> Cache.erase_repo_claim(repo)
      _other -> :ok
    end
  end

  defp redact_status(status) when is_map(status) do
    status
    |> redact_field(:message, &redact_message/1)
    |> redact_field(:queue, fn queue -> Enum.map(queue, &redact_message/1) end)
  end

  defp redact_field(status, field, redact) do
    case status do
      %{^field => value} -> Map.put(status, field, redact.(value))
      _without -> status
    end
  end

  defp redact_message({:update, key, _attrs, actor}), do: {:update, key, :redacted, actor}

  defp redact_message({:"$gen_call", from, {:update, key, _attrs, actor}}),
    do: {:"$gen_call", from, {:update, key, :redacted, actor}}

  defp redact_message(message), do: message
end
