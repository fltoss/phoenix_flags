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

  # Sort position for an entry with no declaration order — i.e. a row in the
  # table that `flags/0` does not mention. Sorts it after every declared flag
  # instead of ahead of them, which `nil` would do.
  @undeclared_sort_position 999_999

  # ============================================================================
  # Public API
  # ============================================================================

  @doc false
  def start_link(%Config{} = config) do
    GenServer.start_link(__MODULE__, config, name: config.name)
  end

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
  def get(instance, key, default \\ nil, opts \\ []) do
    case safe_get_config(instance) do
      {:ok, %{cache_enabled: true}} ->
        case resolve_target(instance, key, opts) do
          {:ok, value} ->
            value

          :none ->
            instance |> read_cached_values() |> Map.get(key, default) |> reject_variant(key)
        end

      {:ok, config} ->
        config |> get_uncached(instance, key, default, opts) |> reject_variant(key)

      :error ->
        default
    end
  end

  # A :variant flag holds a split, not a value, so reading it with get/3 is
  # always a mistake. Benchmarked at ~0ns against the bare read (25ns median
  # either way), so this is guarded here — one place, covering every caller —
  # rather than in per-key clauses generated into each config module.
  defp reject_variant(%PhoenixFlags.Variant{}, key) do
    raise PhoenixFlags.Error,
          "#{inspect(key)} is a :variant flag and has no single value. " <>
            "Read it with variant(#{inspect(key)}, identity) instead of get/2."
  end

  defp reject_variant(value, _key), do: value

  defp get_uncached(config, instance, key, default, opts) do
    case PhoenixFlags.Testing.get_stub(instance, key) do
      {:ok, value} ->
        value

      :none ->
        case resolve_target(instance, key, opts) do
          {:ok, value} -> value
          :none -> fallback_read(config, key, default)
        end
    end
  end

  @doc """
  Returns the targeting rules for a flag, in evaluation order.
  """
  def targets(instance, key) do
    case safe_get_config(instance) do
      {:ok, config} -> load_targets_for(config, key)
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
  """
  def put_target(instance, key, attrs) do
    config = get_config(instance)

    attrs =
      attrs
      |> Map.new()
      |> normalise_conditions()
      |> Map.put(:key, key)
      |> Map.put_new(:position, next_target_position(config, key))

    case fetch_entry(config, key) do
      {:error, :not_found} ->
        {:error, :not_found}

      {:ok, entry} ->
        changeset =
          %PhoenixFlags.Target{}
          |> PhoenixFlags.Target.changeset(attrs)
          |> validate_target_value(config, entry)

        if changeset.valid? do
          insert_target(config, changeset)
        else
          {:error, changeset}
        end
    end
  end

  defp insert_target(%Config{} = config, changeset) do
    case config.repo.insert(changeset) do
      {:ok, target} ->
        refresh_targets(config)
        {:ok, config.repo.preload(target, :conditions)}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Deletes a targeting rule by id. Its conditions go with it.
  """
  def delete_target(instance, target_id) do
    config = get_config(instance)

    case config.repo.get(PhoenixFlags.Target, target_id) do
      nil ->
        {:error, :not_found}

      target ->
        case config.repo.delete(target) do
          {:ok, deleted} ->
            refresh_targets(config)
            {:ok, deleted}

          {:error, changeset} ->
            {:error, changeset}
        end
    end
  rescue
    error ->
      Logger.warning(
        "PhoenixFlags: failed to delete target #{inspect(target_id)}: #{inspect(error)}"
      )

      {:error, :not_found}
  end

  # The documented API takes conditions as keyword lists, which reads better in
  # Elixir than a list of maps; cast_assoc/3 needs maps.
  defp normalise_conditions(%{conditions: conditions} = attrs) when is_list(conditions) do
    %{attrs | conditions: Enum.map(conditions, &condition_map/1)}
  end

  defp normalise_conditions(%{"conditions" => conditions} = attrs) when is_list(conditions) do
    %{attrs | "conditions" => Enum.map(conditions, &condition_map/1)}
  end

  defp normalise_conditions(attrs), do: attrs

  defp condition_map(condition) when is_list(condition), do: Map.new(condition)
  defp condition_map(condition), do: condition

  # Ordered so the overwhelmingly common case is the cheapest: a flag with no
  # rules costs one `:persistent_term` read plus a map lookup and never touches
  # the process dictionary at all. Measured, that beats checking the context
  # first -- `Process.get/1` costs more than the read it would have avoided.
  #
  # The context is only fetched once we know there is a rule that could match,
  # and an empty one short-circuits there: every rule needs at least one
  # condition, and a missing attribute never matches.
  defp resolve_target(instance, key, opts) do
    case instance |> read_cached_targets() |> Map.get(key) do
      {type, targets} -> resolve_with_context(targets, target_context(opts), type)
      _absent -> :none
    end
  rescue
    error ->
      Logger.warning(
        "PhoenixFlags: targeting failed for #{inspect(key)}: #{Exception.message(error)}"
      )

      :none
  end

  defp resolve_with_context(_targets, context, _type) when map_size(context) == 0, do: :none
  defp resolve_with_context(targets, context, type), do: resolve_and_cast(targets, context, type)

  defp resolve_and_cast(targets, context, type) do
    case PhoenixFlags.Target.resolve(targets, context) do
      # A :variant rule names a variant, which `variant/4` returns as-is; casting
      # it as a split would fail. Everything else casts like a stored value.
      {:ok, value} when type == "variant" -> {:ok, value}
      {:ok, value} -> {:ok, Entry.cast_value(value, type)}
      :none -> :none
    end
  end

  defp target_context(opts) do
    case safe_opt(opts, :context, nil) do
      context when is_map(context) -> context
      context when is_list(context) -> Map.new(context)
      _absent -> PhoenixFlags.Context.get()
    end
  end

  defp fetch_entry(%Config{} = config, key) when is_binary(key) do
    case config.repo.get_by(Entry, key: key) do
      %Entry{} = entry -> {:ok, entry}
      nil -> {:error, :not_found}
    end
  end

  defp fetch_entry(_config, _key), do: {:error, :not_found}

  defp validate_target_value(changeset, _config, %Entry{type: "secret"}) do
    Ecto.Changeset.add_error(
      changeset,
      :value,
      "a :secret flag cannot be targeted: the rule value would be stored as plaintext, " <>
        "defeating the encryptor"
    )
  end

  # A :variant rule names one arm of the split, so it is checked against the
  # declared variant names -- not parsed as a weights string, which is what a
  # normal save of a :variant value would be.
  defp validate_target_value(changeset, %Config{} = config, %Entry{type: "variant", key: key}) do
    names = variant_names(config, key)
    value = Ecto.Changeset.get_field(changeset, :value)

    if names == [] or (is_binary(value) and value in names) do
      changeset
    else
      Ecto.Changeset.add_error(
        changeset,
        :value,
        "must name one of the declared variants: #{Enum.join(names, ", ")}"
      )
    end
  end

  # Every other type reuses the changeset a dashboard save goes through, so a
  # rule value cannot be something a normal save would reject.
  defp validate_target_value(changeset, %Config{} = config, %Entry{} = entry) do
    value = Ecto.Changeset.get_field(changeset, :value)

    case value_changeset(config, entry, %{"value" => value}) do
      %{valid?: true} ->
        changeset

      invalid ->
        invalid.errors
        |> Enum.filter(&match?({:value, _}, &1))
        |> Enum.reduce(changeset, fn {:value, {message, opts}}, acc ->
          Ecto.Changeset.add_error(acc, :value, message, opts)
        end)
    end
  end

  defp next_target_position(%Config{} = config, key) do
    import Ecto.Query

    config.repo.one(
      from(t in PhoenixFlags.Target, where: t.key == ^key, select: coalesce(max(t.position), -1))
    ) + 1
  end

  defp refresh_targets(%Config{} = config) do
    store_targets(config)
    notify_peers(config)
  end

  # `:persistent_term.get/2` returns the default for a missing key rather than
  # raising, so no rescue is needed here — unlike the `get/1` calls in
  # `get_config/1` and `safe_get_config/1`.
  defp read_persistent_term(key, default), do: :persistent_term.get(key, default)

  @doc """
  Returns the variant assigned to `identity` for a `:variant` flag.

  Deterministic for a given identity, split and seed — see `PhoenixFlags.Variant`.
  Does no database or process work: the split is parsed once when the cache
  loads, so this is a `:persistent_term` read, a hash and a short list walk.

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
  def variant(instance, key, identity, opts \\ []) do
    case resolve_variant(instance, key, identity, opts) do
      nil -> safe_opt(opts, :default, nil)
      assigned -> maybe_emit_assigned(assigned, instance, key, identity, opts)
    end
  rescue
    error ->
      # Reads must not take down the caller. An unusable identity is a data
      # condition as often as a coding one — an anonymous visitor, a record with
      # no id — so warn loudly and fall back, the same way fallback_read/3 does.
      # `PhoenixFlags.Variant.assign/4` stays strict for direct callers.
      Logger.warning(
        "PhoenixFlags: variant assignment failed for #{inspect(key)}: " <>
          Exception.message(error)
      )

      safe_opt(opts, :default, nil)
  end

  # Every option read on this path tolerates a non-keyword `opts`. The rescue
  # above must not itself be able to raise, and a malformed `opts` should not
  # throw away an assignment that was computed perfectly well.
  defp safe_opt(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)
  defp safe_opt(_opts, _key, default), do: default

  defp resolve_variant(instance, key, identity, opts) do
    case safe_get_config(instance) do
      {:ok, %{cache_enabled: true}} ->
        targeted_or(instance, key, opts, fn ->
          assign_from_cache(instance, key, identity, opts)
        end)

      {:ok, config} ->
        resolve_variant_uncached(config, instance, key, identity, opts)

      :error ->
        nil
    end
  end

  # Mirrors get/3: a stub wins over everything in uncached (test) mode, and it
  # names a variant directly rather than a split to assign from.
  defp resolve_variant_uncached(config, instance, key, identity, opts) do
    case PhoenixFlags.Testing.get_stub(instance, key) do
      {:ok, stubbed} ->
        stubbed

      :none ->
        targeted_or(instance, key, opts, fn ->
          assign_from_db(config, key, identity, opts)
        end)
    end
  end

  # A targeting rule pins the caller to a named arm, overriding the split:
  # "force this for them" would mean little otherwise.
  defp targeted_or(instance, key, opts, otherwise) do
    case resolve_target(instance, key, opts) do
      {:ok, targeted} -> targeted
      :none -> otherwise.()
    end
  end

  defp assign_from_cache(instance, key, identity, opts) do
    instance |> read_cached_values() |> Map.get(key) |> assign_variant(key, identity, opts)
  end

  defp assign_from_db(config, key, identity, opts) do
    config |> variant_from_db(key) |> assign_variant(key, identity, opts)
  end

  defp assign_variant(%PhoenixFlags.Variant{} = variant, key, identity, opts) do
    PhoenixFlags.Variant.assign(variant, key, identity, opts)
  end

  defp assign_variant(_other, _key, _identity, _opts), do: nil

  defp variant_from_db(%Config{}, key) when not is_binary(key), do: nil

  defp variant_from_db(%Config{} = config, key) do
    case config.repo.get_by(Entry, key: key) do
      %Entry{type: "variant"} = entry -> decrypted_cast_value(entry, config)
      _ -> nil
    end
  rescue
    DBConnection.OwnershipError ->
      nil

    error ->
      Logger.warning("PhoenixFlags: variant read failed for #{inspect(key)}: #{inspect(error)}")
      nil
  end

  defp maybe_emit_assigned(assigned, instance, key, identity, opts) do
    if safe_opt(opts, :telemetry, false) do
      :telemetry.execute(
        [:phoenix_flags, :variant, :assigned],
        %{},
        %{instance: instance, flag: key, identity: identity, variant: assigned}
      )
    end

    assigned
  end

  @doc """
  Updates a config entry and refreshes the cache.

  When `cache_enabled: false`, runs in the caller's process for Ecto sandbox compatibility.

  Accepts an optional `:timeout` (in milliseconds, default `5000`).
  """
  def update_entry(instance, key, attrs, opts \\ [])

  # `key` is caller-supplied and the column is a string, so a non-binary key
  # would raise Ecto.Query.CastError from the lookup. The uncached path has no
  # rescue by design (see update_in_caller/4), so screen the key out up front
  # rather than querying with it.
  def update_entry(_instance, key, _attrs, _opts) when not is_binary(key) do
    {:error, :not_found}
  end

  def update_entry(instance, key, attrs, opts) do
    config = get_config(instance)
    actor = Keyword.get(opts, :actor)

    if config.cache_enabled do
      timeout = Keyword.get(opts, :timeout, 5_000)
      GenServer.call(instance, {:update, key, attrs, actor}, timeout)
    else
      case config.repo.get_by(Entry, key: key) do
        nil -> {:error, :not_found}
        entry -> update_in_caller(config, entry, attrs, actor)
      end
    end
  end

  # Uncached writes run in the caller's process, so they bypass the GenServer
  # (and its Ecto sandbox-unfriendly ownership) entirely. Note the deliberate
  # absence of the `rescue` that `do_update/4` has: with no GenServer to keep
  # alive, a database error should surface to the caller. A test that has lost
  # its sandbox connection wants the exception, not an error changeset that
  # hides it.
  defp update_in_caller(config, entry, attrs, actor) do
    old_value = entry.value

    with {:ok, updated} <- config.repo.update(value_changeset(config, entry, attrs)) do
      maybe_audit(config, entry.key, old_value, updated.value, entry.type, actor)
      {:ok, updated}
    end
  end

  # Encrypting and then validating is the one sequence both write paths must
  # perform identically, so it lives here instead of being duplicated. Keeping
  # them in sync by hand is what let `:select` membership go unchecked on both
  # paths at once.
  defp value_changeset(%Config{} = config, %Entry{} = entry, attrs) do
    attrs = maybe_encrypt(attrs, entry.type, config)

    Entry.changeset(entry, attrs,
      select_options: select_options(config, entry.key),
      variants: variant_names(config, entry.key)
    )
  end

  # A module built by `use PhoenixFlags` always generates `select_options/1`,
  # which returns `[]` for anything that is not a `:select` flag. But `:name` is
  # also allowed to be a minimal module exporting only `flags/0` (see
  # `declared_key_set/1` and `PhoenixFlags.Flag.to_seed_map/1`), so fall back to
  # no options — that skips the membership check instead of blocking the write.
  defp select_options(%Config{name: name}, key) do
    Code.ensure_loaded?(name)

    if function_exported?(name, :select_options, 1) do
      name.select_options(key)
    else
      []
    end
  end

  # Same guard and same reason as select_options/2 above.
  defp variant_names(%Config{} = config, key) do
    case declared_variant(config, key) do
      %PhoenixFlags.Flag{} = flag -> Enum.map(PhoenixFlags.Flag.weights(flag), &elem(&1, 0))
      nil -> []
    end
  end

  defp declared_variant(%Config{name: name}, key) do
    Code.ensure_loaded?(name)

    if function_exported?(name, :flags, 0) do
      Enum.find(name.flags(), fn
        %PhoenixFlags.Flag{key: ^key, type: :variant} -> true
        _ -> false
      end)
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
        |> Enum.sort_by(&Map.get(order, &1.key, @undeclared_sort_position))
        |> Enum.group_by(& &1.category)
        |> Enum.sort_by(fn {_category, [first | _]} ->
          Map.get(order, first.key, @undeclared_sort_position)
        end)

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

        config
        |> value_changeset(entry, attrs)
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
      Logger.error("PhoenixFlags: failed to update #{inspect(key)}: #{inspect(error)}")

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
            cond do
              type_changed? ->
                Map.put(metadata_changes, :value, Map.get(declared, :value, ""))

              variant_set_changed?(declared, existing) ->
                Logger.warning(
                  "PhoenixFlags: #{inspect(key)} declares a different set of variants than is stored " <>
                    "(#{inspect(existing.value)} -> #{inspect(declared.value)}); resetting the " <>
                    "split. Any runtime rollout percentages for this flag are lost."
                )

                Map.put(metadata_changes, :value, declared.value)

              true ->
                metadata_changes
            end

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

  # A :variant flag's weights are an operational dial, so a runtime rollout must
  # survive a deploy — that is the whole point, and it is why the stored value is
  # otherwise left alone here.
  #
  # But if the declared *set* of variants changes, the stored split still names
  # variants the code no longer has, and `variant/3` would go on assigning them:
  # callers matching on the declared names then crash on a value that cannot
  # occur in their code. Reset in that case only, mirroring the value reset on a
  # type change. Comparison is by set, so merely reordering the declaration keeps
  # the rollout (order is taken from the stored value).
  defp variant_set_changed?(%{type: "variant", value: declared_value}, existing) do
    variant_name_set(declared_value) != variant_name_set(existing.value)
  end

  defp variant_set_changed?(_declared, _existing), do: false

  defp variant_name_set(value) when is_binary(value) do
    case PhoenixFlags.Variant.parse_weights(value) do
      {:ok, weights} -> weights |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      # Unparseable stored values must also be reset, so give them a set no
      # declaration can equal.
      {:error, _message} -> :unparseable
    end
  end

  defp variant_name_set(_value), do: :unparseable

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

    store_targets(config, entries)
  end

  # Targets live under their own key rather than widening the {values, entries}
  # tuple, which read_cached_values/1 and read_cached_entries/1 both index into
  # by position. Same shape as the :order key.
  #
  # Each key maps to {type, targets}: the type is needed to cast a matching
  # rule's value, and looking it up here means a read does not have to scan the
  # entry list for it.
  defp store_targets(%Config{} = config, entries \\ nil) do
    entries = entries || config.repo.all(Entry)
    types = Map.new(entries, fn entry -> {entry.key, entry.type} end)

    targets =
      config
      |> all_targets()
      |> Enum.group_by(& &1.key)
      |> Enum.reduce(%{}, fn {key, targets}, acc ->
        case Map.fetch(types, key) do
          # Rules for a flag that no longer exists are simply not loaded; the
          # declaration is the source of truth for which flags exist.
          {:ok, type} -> Map.put(acc, key, {type, Enum.sort_by(targets, & &1.position)})
          :error -> acc
        end
      end)

    :persistent_term.put(targets_key(config.name), targets)
  rescue
    error ->
      Logger.warning("PhoenixFlags: failed to load targeting rules: #{inspect(error)}")
      :ok
  end

  defp all_targets(%Config{} = config) do
    import Ecto.Query

    config.repo.all(
      from(t in PhoenixFlags.Target,
        order_by: [asc: t.key, asc: t.position],
        preload: :conditions
      )
    )
  end

  defp load_targets_for(%Config{} = config, key) when is_binary(key) do
    import Ecto.Query

    config.repo.all(
      from(t in PhoenixFlags.Target,
        where: t.key == ^key,
        order_by: [asc: t.position],
        preload: :conditions
      )
    )
  rescue
    error ->
      Logger.warning(
        "PhoenixFlags: failed to read targeting rules for #{inspect(key)}: #{inspect(error)}"
      )

      []
  end

  defp load_targets_for(_config, _key), do: []

  defp read_cached_targets(instance) do
    read_persistent_term(targets_key(instance), %{})
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
          "PhoenixFlags: failed to decrypt secret #{inspect(key)}: decrypt/1 returned #{inspect(other)}"
        )

        nil
    end
  rescue
    error ->
      Logger.warning("PhoenixFlags: failed to decrypt secret #{inspect(key)}: #{inspect(error)}")
      nil
  end

  # ttl and seed are declaration-level, so they are applied here rather than in
  # Entry.cast_value/2, which only sees the stored string.
  defp decrypted_cast_value(%Entry{type: "variant", value: value, key: key}, %Config{} = config) do
    case Entry.cast_value(value, "variant") do
      %PhoenixFlags.Variant{} = variant ->
        case declared_variant(config, key) do
          %PhoenixFlags.Flag{ttl: ttl, seed: seed} -> %{variant | ttl: ttl, seed: seed}
          nil -> variant
        end

      nil ->
        nil
    end
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

  defp fallback_read(%Config{}, key, default) when not is_binary(key), do: default

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
      Logger.warning("PhoenixFlags: fallback read failed for #{inspect(key)}: #{inspect(error)}")
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
  defp targets_key(instance), do: {PhoenixFlags, instance, :targets}
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
