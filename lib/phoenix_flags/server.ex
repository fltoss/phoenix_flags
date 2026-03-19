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
    load_cache(config)
    {:ok, config}
  end

  @impl true
  def handle_call({:update, key, attrs}, _from, %Config{} = config) do
    case config.repo.get_by(Entry, key: key) do
      nil ->
        {:reply, {:error, :not_found}, config}

      entry ->
        case entry |> Entry.changeset(attrs) |> config.repo.update() do
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
    DBConnection.OwnershipError -> default
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
    ArgumentError ->
      raise "PhoenixFlags instance #{inspect(instance)} is not running"
  end
end
