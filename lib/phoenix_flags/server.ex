defmodule PhoenixFlags.Server do
  @moduledoc """
  GenServer that manages the persistent_term cache and DB writes.

  Each `use PhoenixFlags` module starts its own Server instance,
  named after the module. Reads go directly to `:persistent_term` (zero-cost).
  Writes go through the GenServer to serialise DB updates and cache reloads.
  """
  use GenServer

  alias PhoenixFlags.Config
  alias PhoenixFlags.Entry

  require Logger

  # ============================================================================
  # Public API
  # ============================================================================

  @doc false
  def start_link(%Config{} = config) do
    GenServer.start_link(__MODULE__, config, name: config.name)
  end

  @doc """
  Returns the cached value for a config key.

  When `cache_enabled: false`, checks the process dictionary first
  (for test overrides), then falls back to a direct DB read.
  """
  def get(instance, key, default \\ nil) do
    case safe_get_config(instance) do
      {:ok, %{cache_enabled: true}} ->
        instance |> read_cached_values() |> Map.get(key, default)

      {:ok, config} ->
        get_uncached(config, instance, key, default)

      :error ->
        default
    end
  end

  defp get_uncached(config, instance, key, default) do
    case PhoenixFlags.Testing.get_stub(instance, key) do
      {:ok, value} -> value
      :none -> fallback_read(config, key, default)
    end
  end

  defp read_persistent_term(key, default) do
    :persistent_term.get(key, default)
  rescue
    ArgumentError -> default
  end

  @doc """
  Updates a config entry and refreshes the cache.

  When `cache_enabled: false`, runs in the caller's process for Ecto sandbox compatibility.

  Accepts an optional `:timeout` (in milliseconds, default `5000`).
  """
  def update_entry(instance, key, attrs, opts \\ []) do
    config = get_config(instance)
    actor = Keyword.get(opts, :actor)

    if config.cache_enabled do
      timeout = Keyword.get(opts, :timeout, 5_000)
      GenServer.call(instance, {:update, key, attrs, actor}, timeout)
    else
      case config.repo.get_by(Entry, key: key) do
        nil ->
          {:error, :not_found}

        entry ->
          old_value = entry.value
          attrs = maybe_encrypt(attrs, entry.type, config)

          case entry |> Entry.changeset(attrs) |> config.repo.update() do
            {:ok, updated} ->
              maybe_audit(config, key, old_value, updated.value, entry.type, actor)
              {:ok, updated}

            error ->
              error
          end
      end
    end
  end

  @doc """
  Returns all audit log entries, newest first.

  Raises `PhoenixFlags.Error` unless the instance is configured with `audit: true`.
  """
  def audit_log(instance) do
    import Ecto.Query
    config = ensure_audit_enabled!(get_config(instance))

    config.repo.all(from(a in PhoenixFlags.AuditLog, order_by: [desc: a.inserted_at, desc: a.id]))
  end

  @doc """
  Returns audit log entries for a specific key, newest first.

  Raises `PhoenixFlags.Error` unless the instance is configured with `audit: true`.
  """
  def audit_log(instance, key) do
    import Ecto.Query
    config = ensure_audit_enabled!(get_config(instance))

    config.repo.all(
      from(a in PhoenixFlags.AuditLog,
        where: a.key == ^key,
        order_by: [desc: a.inserted_at, desc: a.id]
      )
    )
  end

  defp ensure_audit_enabled!(%Config{audit: true} = config), do: config

  defp ensure_audit_enabled!(%Config{name: name}) do
    raise PhoenixFlags.Error,
          "audit_log is not available because #{inspect(name)} is not configured with " <>
            "`audit: true`. Enable it in your `use PhoenixFlags` options and run the V2 " <>
            "migration (PhoenixFlags.Migration.up(version: 2)) to create the audit table."
  end

  @doc """
  Returns the config for the given instance. Used by the UI to resolve actor.
  """
  def config(instance) do
    :persistent_term.get({PhoenixFlags, instance, :config})
  end

  @doc """
  Returns all config entries grouped by category.
  """
  def all_grouped(instance) do
    case safe_get_config(instance) do
      {:ok, config} ->
        entries =
          if config.cache_enabled do
            read_cached_entries(instance)
          else
            config.repo.all(Entry)
          end

        order = read_flag_order(instance)

        entries
        |> Enum.sort_by(&Map.get(order, &1.key, 999_999))
        |> Enum.group_by(& &1.category)
        |> Enum.sort_by(fn {_category, [first | _]} -> Map.get(order, first.key, 999_999) end)

      :error ->
        []
    end
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(%Config{} = config) do
    Process.flag(:trap_exit, true)
    validate_encryptor!(config)
    claim_repo!(config)
    :persistent_term.put(config_key(config.name), config)
    store_flag_order(config)
    seed_flags(config)
    load_cache(config)
    schedule_refresh(config)
    {:ok, config}
  end

  defp validate_encryptor!(%Config{encryptor: nil, name: name} = _config) do
    if Enum.any?(name.flags(), &(&1.type == :secret)) do
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

  @impl true
  def handle_call({:update, key, attrs, actor}, _from, %Config{} = config) do
    {:reply, do_update(config, key, attrs, actor), config}
  end

  # A DB error (connection loss, constraint violation, ...) must not crash
  # the Server: that would erase nothing but still restart the process and
  # re-seed. Convert exceptions into an error changeset the caller (and the
  # dashboard form) can render.
  defp do_update(%Config{} = config, key, attrs, actor) do
    case config.repo.get_by(Entry, key: key) do
      nil ->
        {:error, :not_found}

      entry ->
        old_value = entry.value
        attrs = maybe_encrypt(attrs, entry.type, config)

        entry
        |> Entry.changeset(attrs)
        |> config.repo.update()
        |> case do
          {:ok, updated} ->
            try do
              patch_cache(config, updated)
            rescue
              error ->
                Logger.error(
                  "PhoenixFlags: failed to update cache after write: #{inspect(error)}"
                )
            end

            maybe_audit(config, key, old_value, updated.value, entry.type, actor)
            notify_peers(config)
            {:ok, updated}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  rescue
    error ->
      Logger.error("PhoenixFlags: failed to update #{key}: #{inspect(error)}")

      changeset =
        %Entry{key: key}
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.add_error(:value, "could not be saved (database error)")
        |> Map.put(:action, :update)

      {:error, changeset}
  end

  @impl true
  def handle_info(:reload, %Config{} = config) do
    try do
      load_cache(config)
    rescue
      error ->
        Logger.error("PhoenixFlags: failed to reload cache: #{inspect(error)}")
    end

    {:noreply, config}
  end

  @impl true
  def handle_info(:refresh, %Config{} = config) do
    try do
      load_cache(config)
    rescue
      error ->
        Logger.error("PhoenixFlags: periodic cache refresh failed: #{inspect(error)}")
    end

    schedule_refresh(config)
    {:noreply, config}
  end

  @impl true
  def handle_info(_msg, config) do
    {:noreply, config}
  end

  @impl true
  def terminate(_reason, %Config{} = config) do
    # Leave the cache, config, and order keys intact so that get/3 and
    # all_grouped/0 can keep serving (possibly stale) values during a
    # restart. init/1 overwrites them with fresh data. Only the repo
    # claim is released — it guards concurrently *running* instances.
    release_repo_claim(config)
  rescue
    error ->
      Logger.debug("PhoenixFlags: terminate cleanup failed: #{inspect(error)}")
      :ok
  end

  # ============================================================================
  # Internal
  # ============================================================================

  defp seed_flags(%Config{} = config) do
    declared_flags =
      config.name.flags()
      |> Enum.map(&PhoenixFlags.Flag.to_seed_map/1)
      |> Enum.map(&encrypt_seed_value(&1, config))

    declared_by_key = Map.new(declared_flags, &{&1.key, &1})
    declared_keys = MapSet.new(declared_flags, & &1.key)

    existing_entries = config.repo.all(Entry)
    existing_by_key = Map.new(existing_entries, &{&1.key, &1})
    existing_keys = MapSet.new(existing_entries, & &1.key)

    changed? = do_seed_inserts(config, declared_flags, declared_keys, existing_keys)

    changed? =
      do_seed_updates(config, declared_by_key, declared_keys, existing_by_key, existing_keys) or
        changed?

    changed? = do_seed_deletes(config, declared_keys, existing_keys) or changed?

    if changed?, do: notify_peers(config)
  rescue
    error ->
      Logger.warning("PhoenixFlags: failed to sync flags: #{inspect(error)}")
      # Notify peers anyway — partial changes may have been committed
      notify_peers(config)
  end

  defp do_seed_inserts(config, declared_flags, declared_keys, existing_keys) do
    keys_to_insert = MapSet.difference(declared_keys, existing_keys)

    if MapSet.size(keys_to_insert) > 0 do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      new_entries =
        declared_flags
        |> Enum.filter(fn flag -> MapSet.member?(keys_to_insert, flag.key) end)
        |> Enum.map(fn flag ->
          flag
          |> Map.put(:id, Ecto.UUID.generate())
          |> Map.put(:inserted_at, now)
          |> Map.put(:updated_at, now)
        end)

      {count, _} = config.repo.insert_all(Entry, new_entries, on_conflict: :nothing)
      Logger.info("PhoenixFlags: seeded #{count} new flag(s) (#{length(new_entries)} declared)")
      true
    else
      false
    end
  end

  defp do_seed_updates(config, declared_by_key, declared_keys, existing_by_key, existing_keys) do
    keys_to_check = MapSet.intersection(declared_keys, existing_keys)

    changesets =
      for key <- keys_to_check, reduce: [] do
        acc ->
          declared = declared_by_key[key]
          existing = existing_by_key[key]

          declared_type = Map.get(declared, :type, "string")
          type_changed? = existing.type != declared_type

          metadata_changes =
            %{}
            |> maybe_change(:label, existing.label, Map.get(declared, :label, key))
            |> maybe_change(:description, existing.description, Map.get(declared, :description))
            |> maybe_change(:category, existing.category, Map.get(declared, :category, "default"))
            |> maybe_change(:type, existing.type, declared_type)

          metadata_changes =
            if type_changed?,
              do: Map.put(metadata_changes, :value, Map.get(declared, :value, "")),
              else: metadata_changes

          if map_size(metadata_changes) > 0 do
            [{existing, metadata_changes} | acc]
          else
            acc
          end
      end

    if changesets == [] do
      false
    else
      apply_metadata_updates(config, changesets)
    end
  end

  defp apply_metadata_updates(config, changesets) do
    result =
      config.repo.transaction(fn ->
        Enum.each(changesets, &apply_single_update(config, &1))
      end)

    case result do
      {:ok, _} ->
        true

      {:error, reason} ->
        Logger.warning("PhoenixFlags: failed to update flag metadata: #{inspect(reason)}")
        false
    end
  end

  defp apply_single_update(config, {existing, changes}) do
    existing
    |> Ecto.Changeset.change(changes)
    |> config.repo.update!()

    Logger.info(
      "PhoenixFlags: updated metadata for #{existing.key}: #{inspect(Map.keys(changes))}"
    )
  end

  defp do_seed_deletes(config, declared_keys, existing_keys) do
    keys_to_remove = MapSet.difference(existing_keys, declared_keys)

    if MapSet.size(keys_to_remove) > 0 do
      import Ecto.Query

      keys_list = MapSet.to_list(keys_to_remove)

      Entry
      |> where([e], e.key in ^keys_list)
      |> config.repo.delete_all()

      Logger.info(
        "PhoenixFlags: removed #{MapSet.size(keys_to_remove)} stale flag(s): #{Enum.join(keys_list, ", ")}"
      )

      true
    else
      false
    end
  end

  defp maybe_change(changes, _field, same, same), do: changes
  defp maybe_change(changes, field, _old, new), do: Map.put(changes, field, new)

  # Secret defaults must never reach the database as plaintext. Encrypting
  # here covers both seed inserts and the value reset on type changes.
  defp encrypt_seed_value(%{type: "secret", value: value} = seed_map, %Config{
         encryptor: encryptor
       })
       when value not in [nil, ""] and not is_nil(encryptor) do
    %{seed_map | value: encryptor.encrypt(value)}
  end

  defp encrypt_seed_value(seed_map, _config), do: seed_map

  defp load_cache(%Config{} = config) do
    entries = config.repo.all(Entry)

    values =
      Map.new(entries, fn entry -> {entry.key, decrypted_cast_value(entry, config)} end)

    :persistent_term.put(cache_key(config.name), {values, entries})
  end

  defp patch_cache(%Config{} = config, %Entry{} = updated) do
    {values, entries} = read_persistent_term(cache_key(config.name), {%{}, []})

    new_values = Map.put(values, updated.key, decrypted_cast_value(updated, config))
    new_entries = Enum.map(entries, fn e -> if e.key == updated.key, do: updated, else: e end)

    :persistent_term.put(cache_key(config.name), {new_values, new_entries})
  end

  defp decrypted_cast_value(%Entry{type: "secret", value: ""}, _config), do: nil

  defp decrypted_cast_value(%Entry{type: "secret", value: value, key: key}, %Config{
         encryptor: encryptor
       })
       when not is_nil(encryptor) do
    # Some crypto APIs (e.g. :crypto.crypto_one_time_aead/7) signal failure
    # by returning the atom :error instead of raising — never cache that as
    # if it were the plaintext.
    case encryptor.decrypt(value) do
      plaintext when is_binary(plaintext) ->
        plaintext

      other ->
        Logger.warning(
          "PhoenixFlags: failed to decrypt secret #{key}: decrypt/1 returned #{inspect(other)}"
        )

        nil
    end
  rescue
    error ->
      Logger.warning("PhoenixFlags: failed to decrypt secret #{key}: #{inspect(error)}")
      nil
  end

  defp decrypted_cast_value(%Entry{value: value, type: type}, _config) do
    Entry.cast_value(value, type)
  end

  defp store_flag_order(%Config{} = config) do
    order =
      config.name.flags()
      |> Enum.with_index()
      |> Map.new(fn {flag, index} -> {flag.key, index} end)

    :persistent_term.put(order_key(config.name), order)
  end

  defp read_flag_order(instance) do
    read_persistent_term(order_key(instance), %{})
  end

  defp fallback_read(%Config{} = config, key, default) do
    case config.repo.get_by(Entry, key: key) do
      # Same pipeline as the cached path — secrets must be decrypted here
      # too, or uncached reads would return the stored ciphertext.
      %Entry{} = entry -> decrypted_cast_value(entry, config)
      nil -> default
    end
  rescue
    DBConnection.OwnershipError ->
      default

    error ->
      Logger.warning("PhoenixFlags: fallback read failed for #{key}: #{inspect(error)}")
      default
  end

  defp maybe_audit(%Config{audit: true} = config, key, old_value, new_value, type, actor) do
    config.repo.insert(%PhoenixFlags.AuditLog{
      key: key,
      old_value: redact_if_secret(old_value, type),
      new_value: redact_if_secret(new_value, type),
      actor: actor || "unknown"
    })
  rescue
    error ->
      Logger.error("PhoenixFlags: failed to insert audit log: #{inspect(error)}")
  end

  defp maybe_audit(_config, _key, _old_value, _new_value, _type, _actor), do: :ok

  defp redact_if_secret("", _type), do: ""
  defp redact_if_secret(nil, _type), do: nil
  defp redact_if_secret(_value, "secret"), do: "[redacted]"
  defp redact_if_secret(value, _type), do: value

  defp maybe_encrypt(attrs, "secret", %Config{encryptor: encryptor}) when not is_nil(encryptor) do
    case fetch_value(attrs) do
      {:ok, _key, ""} -> attrs
      {:ok, map_key, value} -> Map.put(attrs, map_key, encryptor.encrypt(value))
      :error -> attrs
    end
  end

  defp maybe_encrypt(attrs, _type, _config), do: attrs

  defp fetch_value(%{"value" => value}), do: {:ok, "value", value}
  defp fetch_value(%{value: value}), do: {:ok, :value, value}
  defp fetch_value(_), do: :error

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

  defp read_cached_values(instance) do
    instance |> cache_key() |> read_persistent_term({%{}, []}) |> elem(0)
  end

  defp read_cached_entries(instance) do
    instance |> cache_key() |> read_persistent_term({%{}, []}) |> elem(1)
  end

  # Two config modules with *different* flag declarations sharing one repo
  # would delete each other's rows at seed time (undeclared keys are removed).
  # Same declarations are allowed — that's the normal multi-node cluster
  # scenario exercised with two local instances in tests.
  defp claim_repo!(%Config{repo: repo, name: name} = config) do
    claim_key = repo_claim_key(repo)
    declared_keys = declared_key_set(config)
    claim = %{name: name, keys: declared_keys}

    case read_persistent_term(claim_key, nil) do
      nil ->
        :persistent_term.put(claim_key, claim)

      %{name: ^name} ->
        :persistent_term.put(claim_key, claim)

      %{name: other, keys: other_keys} ->
        cond do
          not instance_alive?(other) ->
            :persistent_term.put(claim_key, claim)

          MapSet.equal?(declared_keys, other_keys) ->
            :ok

          true ->
            raise PhoenixFlags.Error,
                  "#{inspect(name)} and #{inspect(other)} both use repo #{inspect(repo)} " <>
                    "but declare different flags. PhoenixFlags stores all flags in one " <>
                    "system_flags table and removes undeclared keys at startup, so two " <>
                    "config modules on the same repo would delete each other's flags. " <>
                    "Use one config module per repo."
        end
    end
  end

  defp release_repo_claim(%Config{repo: repo, name: name}) do
    claim_key = repo_claim_key(repo)

    case read_persistent_term(claim_key, nil) do
      %{name: ^name} -> :persistent_term.erase(claim_key)
      _ -> :ok
    end
  end

  defp instance_alive?(instance) when is_atom(instance) do
    is_pid(Process.whereis(instance))
  end

  defp declared_key_set(%Config{name: name}) do
    MapSet.new(name.flags(), fn
      %PhoenixFlags.Flag{key: key} -> key
      %{key: key} -> key
    end)
  end

  defp schedule_refresh(%Config{cache_enabled: true, refresh_interval: interval})
       when is_integer(interval) and interval > 0 do
    # Jitter avoids synchronised reload stampedes across cluster nodes.
    jitter = :rand.uniform(max(div(interval, 10), 1))
    Process.send_after(self(), :refresh, interval + jitter)
    :ok
  end

  defp schedule_refresh(%Config{}), do: :ok

  defp cache_key(instance), do: {PhoenixFlags, instance, :cache}
  defp config_key(instance), do: {PhoenixFlags, instance, :config}
  defp order_key(instance), do: {PhoenixFlags, instance, :order}
  defp repo_claim_key(repo), do: {PhoenixFlags, :repo_claim, repo}

  defp get_config(instance) do
    :persistent_term.get(config_key(instance))
  rescue
    _error in ArgumentError ->
      reraise PhoenixFlags.Error,
              "PhoenixFlags instance #{inspect(instance)} is not running",
              __STACKTRACE__
  end

  defp safe_get_config(instance) do
    {:ok, :persistent_term.get(config_key(instance))}
  rescue
    ArgumentError -> :error
  end
end
