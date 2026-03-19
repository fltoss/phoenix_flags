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
      {:ok, config} ->
        if config.cache_enabled do
          instance
          |> read_cached_values()
          |> Map.get(key, default)
        else
          case PhoenixFlags.Testing.get_override(instance, key) do
            {:ok, value} -> value
            :none -> fallback_read(config, key, default)
          end
        end

      :error ->
        default
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

    if config.cache_enabled do
      timeout = Keyword.get(opts, :timeout, 5_000)
      GenServer.call(instance, {:update, key, attrs}, timeout)
    else
      case config.repo.get_by(Entry, key: key) do
        nil -> {:error, :not_found}
        entry -> entry |> Entry.changeset(attrs) |> config.repo.update()
      end
    end
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

        entries
        |> Enum.group_by(& &1.category)
        |> Enum.sort_by(fn {category, _} -> category end)

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
    :persistent_term.put(config_key(config.name), config)
    seed_flags(config)
    load_cache(config)
    {:ok, config}
  end

  @impl true
  def handle_call({:update, key, attrs}, _from, %Config{} = config) do
    case config.repo.get_by(Entry, key: key) do
      nil ->
        {:reply, {:error, :not_found}, config}

      entry ->
        entry
        |> Entry.changeset(attrs)
        |> config.repo.update()
        |> case do
          {:ok, updated} ->
            try do
              load_cache(config)
            rescue
              error ->
                Logger.warning("PhoenixFlags: failed to reload cache after update: #{inspect(error)}")
            end

            notify_peers(config)
            {:reply, {:ok, updated}, config}

          {:error, changeset} ->
            {:reply, {:error, changeset}, config}
        end
    end
  end

  @impl true
  def handle_info(:reload, %Config{} = config) do
    try do
      load_cache(config)
    rescue
      error ->
        Logger.warning("PhoenixFlags: failed to reload cache: #{inspect(error)}")
    end

    {:noreply, config}
  end

  @impl true
  def handle_info(_msg, config) do
    {:noreply, config}
  end

  @impl true
  def terminate(_reason, %Config{} = config) do
    # Only erase the config key. Leave cache and entries intact so that
    # get/3 can still serve (possibly stale) values during a restart.
    # init/1 will overwrite them with fresh data.
    :persistent_term.erase(config_key(config.name))
  rescue
    _ -> :ok
  end

  # ============================================================================
  # Internal
  # ============================================================================

  defp seed_flags(%Config{} = config) do
    declared_flags =
      config.name.flags()
      |> Enum.map(&PhoenixFlags.Flag.to_seed_map/1)

    declared_by_key = Map.new(declared_flags, &{&1.key, &1})
    declared_keys = MapSet.new(declared_flags, & &1.key)

    existing_entries = config.repo.all(Entry)
    existing_by_key = Map.new(existing_entries, &{&1.key, &1})
    existing_keys = MapSet.new(existing_entries, & &1.key)

    changed? = do_seed_inserts(config, declared_flags, declared_keys, existing_keys)
    changed? = do_seed_updates(config, declared_by_key, declared_keys, existing_by_key, existing_keys) or changed?
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

      config.repo.insert_all(Entry, new_entries, on_conflict: :nothing)
      Logger.info("PhoenixFlags: seeded #{length(new_entries)} new flag(s)")
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

    if changesets != [] do
      case config.repo.transaction(fn ->
             for {existing, changes} <- changesets do
               existing
               |> Ecto.Changeset.change(changes)
               |> config.repo.update!()

               Logger.info(
                 "PhoenixFlags: updated metadata for #{existing.key}: #{inspect(Map.keys(changes))}"
               )
             end
           end) do
        {:ok, _} ->
          true

        {:error, reason} ->
          Logger.warning("PhoenixFlags: failed to update flag metadata: #{inspect(reason)}")
          false
      end
    else
      false
    end
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

  defp load_cache(%Config{} = config) do
    entries = config.repo.all(Entry)

    values = Map.new(entries, fn entry -> {entry.key, Entry.cast_value(entry.value, entry.type)} end)

    :persistent_term.put(cache_key(config.name), {values, entries})
  end

  defp fallback_read(%Config{} = config, key, default) do
    case config.repo.get_by(Entry, key: key) do
      %Entry{value: value, type: type} -> Entry.cast_value(value, type)
      nil -> default
    end
  rescue
    DBConnection.OwnershipError ->
      default

    error ->
      Logger.warning("PhoenixFlags: fallback read failed for #{key}: #{inspect(error)}")
      default
  end

  defp notify_peers(%Config{} = config) do
    for node <- Node.list() do
      send({config.name, node}, :reload)
    end
  end

  defp read_cached_values(instance) do
    instance |> cache_key() |> read_persistent_term({%{}, []}) |> elem(0)
  end

  defp read_cached_entries(instance) do
    instance |> cache_key() |> read_persistent_term({%{}, []}) |> elem(1)
  end

  defp cache_key(instance), do: {PhoenixFlags, instance, :cache}
  defp config_key(instance), do: {PhoenixFlags, instance, :config}

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
