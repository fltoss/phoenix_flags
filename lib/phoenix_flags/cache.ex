defmodule PhoenixFlags.Cache do
  @moduledoc false

  # Every :persistent_term key PhoenixFlags uses, and the only module that
  # writes one. Reads never raise: a missing key is the empty value.
  #
  # Values and entries share one key so a reader never sees the values of one
  # load with the entries of another. Targets, the declaration order and the
  # config have their own.

  alias PhoenixFlags.Config

  @empty_entries {%{}, []}

  def put_config(%Config{name: name} = config), do: put(config_key(name), config)

  @doc "`{:ok, config}`, or `:error` when the instance is not running."
  def config(instance) do
    case :persistent_term.get(config_key(instance), nil) do
      %Config{} = config -> {:ok, config}
      nil -> :error
    end
  end

  @doc "The config, raising `PhoenixFlags.Error` when the instance is not running."
  def config!(instance) do
    case config(instance) do
      {:ok, config} ->
        config

      :error ->
        raise PhoenixFlags.Error, "PhoenixFlags instance #{inspect(instance)} is not running"
    end
  end

  def values(instance), do: instance |> entries_key() |> get(@empty_entries) |> elem(0)
  def entries(instance), do: instance |> entries_key() |> get(@empty_entries) |> elem(1)

  def put_entries(name, values, entries), do: put(entries_key(name), {values, entries})

  @doc "Replaces one entry and its value, leaving the rest of the load as it was."
  def patch_entry(name, entry, value) do
    {values, entries} = get(entries_key(name), @empty_entries)

    entries =
      Enum.map(entries, fn existing -> if existing.key == entry.key, do: entry, else: existing end)

    put_entries(name, Map.put(values, entry.key, value), entries)
  end

  def targets(instance), do: get(targets_key(instance), %{})
  def put_targets(name, targets), do: put(targets_key(name), targets)

  def order(instance), do: get(order_key(instance), %{})
  def put_order(name, order), do: put(order_key(name), order)

  def repo_claim(repo), do: get(repo_claim_key(repo), nil)
  def put_repo_claim(repo, claim), do: put(repo_claim_key(repo), claim)
  def erase_repo_claim(repo), do: :persistent_term.erase(repo_claim_key(repo))

  defp get(key, default), do: :persistent_term.get(key, default)
  defp put(key, term), do: :persistent_term.put(key, term)

  defp entries_key(instance), do: {PhoenixFlags, instance, :cache}
  defp config_key(instance), do: {PhoenixFlags, instance, :config}
  defp order_key(instance), do: {PhoenixFlags, instance, :order}
  defp targets_key(instance), do: {PhoenixFlags, instance, :targets}
  defp repo_claim_key(repo), do: {PhoenixFlags, :repo_claim, repo}
end
