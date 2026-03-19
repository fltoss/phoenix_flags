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
    config = get_config(instance)

    if config.cache_enabled do
      cache_key(instance)
      |> :persistent_term.get(%{})
      |> Map.get(key, default)
    else
      case PhoenixFlags.Testing.get_override(instance, key) do
        {:ok, value} -> value
        :none -> fallback_read(config, key, default)
      end
    end
  rescue
    ArgumentError -> fallback_read(get_config(instance), key, default)
  end

  @doc """
  Updates a config entry and refreshes the cache.

  When `cache_enabled: false`, runs in the caller's process for Ecto sandbox compatibility.
  """
  def update_entry(instance, key, attrs) do
    config = get_config(instance)

    if config.cache_enabled do
      GenServer.call(instance, {:update, key, attrs})
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
    config = get_config(instance)

    Entry
    |> config.repo.all()
    |> Enum.group_by(& &1.category)
    |> Enum.sort_by(fn {category, _} -> category end)
  end

  # ============================================================================
  # GenServer Callbacks
  # ============================================================================

  @impl true
  def init(%Config{} = config) do
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
            load_cache(config)
            notify_peers(config)
            {:reply, {:ok, updated}, config}

          {:error, changeset} ->
            {:reply, {:error, changeset}, config}
        end
    end
  end

  @impl true
  def handle_info(:reload, %Config{} = config) do
    load_cache(config)
    {:noreply, config}
  end

  # ============================================================================
  # Internal
  # ============================================================================

  defp seed_flags(%Config{} = config) do
    declared_flags =
      config.name.flags()
      |> Enum.map(fn
        %PhoenixFlags.Flag{} = flag -> PhoenixFlags.Flag.to_seed_map(flag)
        %{key: _} = map -> map
      end)

    declared_by_key = Map.new(declared_flags, &{&1.key, &1})
    declared_keys = MapSet.new(declared_flags, & &1.key)

    existing_entries = config.repo.all(Entry)
    existing_by_key = Map.new(existing_entries, &{&1.key, &1})
    existing_keys = MapSet.new(existing_entries, & &1.key)

    # Insert flags that are declared but don't exist in the DB
    keys_to_insert = MapSet.difference(declared_keys, existing_keys)

    if MapSet.size(keys_to_insert) > 0 do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      new_entries =
        declared_flags
        |> Enum.filter(fn flag -> MapSet.member?(keys_to_insert, flag.key) end)
        |> Enum.map(fn flag ->
          %{
            id: Ecto.UUID.generate(),
            key: flag.key,
            value: Map.get(flag, :value, ""),
            type: Map.get(flag, :type, "string"),
            category: Map.get(flag, :category, "default"),
            label: Map.get(flag, :label, flag.key),
            description: Map.get(flag, :description),
            inserted_at: now,
            updated_at: now
          }
        end)

      config.repo.insert_all(Entry, new_entries)
      Logger.info("PhoenixFlags: seeded #{length(new_entries)} new flag(s)")
    end

    # Update metadata (label, description, category, type) for existing flags
    # that have changed. Preserves the runtime value unless the type changed,
    # in which case the value is reset to the declared default.
    keys_to_check = MapSet.intersection(declared_keys, existing_keys)

    for key <- keys_to_check do
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

      # If the type changed, the old value is likely invalid — reset to declared default
      metadata_changes =
        if type_changed?,
          do: Map.put(metadata_changes, :value, Map.get(declared, :value, "")),
          else: metadata_changes

      if map_size(metadata_changes) > 0 do
        existing
        |> Ecto.Changeset.change(metadata_changes)
        |> config.repo.update!()

        Logger.info("PhoenixFlags: updated metadata for #{key}: #{inspect(Map.keys(metadata_changes))}")
      end
    end

    # Remove flags that exist in the DB but are no longer declared
    keys_to_remove = MapSet.difference(existing_keys, declared_keys)

    if MapSet.size(keys_to_remove) > 0 do
      import Ecto.Query

      keys_list = MapSet.to_list(keys_to_remove)

      Entry
      |> where([e], e.key in ^keys_list)
      |> config.repo.delete_all()

      Logger.info("PhoenixFlags: removed #{MapSet.size(keys_to_remove)} stale flag(s): #{Enum.join(keys_list, ", ")}")
    end
  rescue
    error ->
      Logger.warning("PhoenixFlags: failed to sync flags: #{inspect(error)}")
  end

  defp maybe_change(changes, _field, same, same), do: changes
  defp maybe_change(changes, field, _old, new), do: Map.put(changes, field, new)

  defp load_cache(%Config{} = config) do
    cache =
      Entry
      |> config.repo.all()
      |> Map.new(fn entry -> {entry.key, Entry.cast_value(entry.value, entry.type)} end)

    :persistent_term.put(cache_key(config.name), cache)
  rescue
    error ->
      Logger.warning("PhoenixFlags: failed to load cache: #{inspect(error)}")
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

  defp cache_key(instance), do: {PhoenixFlags, instance, :cache}
  defp config_key(instance), do: {PhoenixFlags, instance, :config}

  defp get_config(instance) do
    :persistent_term.get(config_key(instance))
  rescue
    _error in ArgumentError ->
      reraise "PhoenixFlags instance #{inspect(instance)} is not running", __STACKTRACE__
  end
end
