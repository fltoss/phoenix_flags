defmodule PhoenixFlags.Seed do
  @moduledoc false

  # Brings the table in line with what the code declares, at startup: inserts
  # new flags and keeps metadata current. It never deletes a row and never
  # resets a value a declaration still accepts, because in a rolling deploy the
  # old and new releases disagree on both. prune/1 is the deliberate delete.

  import Ecto.Query

  alias PhoenixFlags.Config
  alias PhoenixFlags.Declarations
  alias PhoenixFlags.Entry
  alias PhoenixFlags.Flag
  alias PhoenixFlags.Store
  alias PhoenixFlags.Values

  require Logger

  @doc "Syncs declarations into the table. Returns whether anything changed."
  def sync(%Config{name: name} = config) do
    declared =
      name
      |> Declarations.all()
      |> Enum.map(&(&1 |> Flag.to_seed_map() |> Values.encrypt_seed(config)))

    existing = Map.new(Store.all(config), &{&1.key, &1})

    inserted? = insert_missing(config, Enum.reject(declared, &Map.has_key?(existing, &1.key)))
    updated? = update_metadata(config, declared, existing)
    log_undeclared(existing, declared)

    inserted? or updated?
  rescue
    error ->
      Logger.warning("PhoenixFlags: failed to sync flags: #{inspect(error)}")
      # Partial changes may have been committed, so report a change.
      true
  end

  @doc "Deletes stored flags no longer declared, with their rules. Returns the keys."
  def prune(%Config{name: name} = config) do
    declared = Declarations.keys(name)

    keys =
      from(e in Entry, select: e.key)
      |> config.repo.all()
      |> Enum.reject(&MapSet.member?(declared, &1))
      |> Enum.sort()

    if keys != [] do
      config.repo.delete_all(from(e in Entry, where: e.key in ^keys))
      delete_rules(config, keys)

      Logger.info(
        "PhoenixFlags: pruned #{length(keys)} undeclared flag(s): #{Enum.join(keys, ", ")}"
      )
    end

    keys
  end

  defp insert_missing(_config, []), do: false

  defp insert_missing(config, seeds) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    rows =
      Enum.map(
        seeds,
        &Map.merge(&1, %{id: Ecto.UUID.generate(), inserted_at: now, updated_at: now})
      )

    {count, _} = config.repo.insert_all(Entry, rows, on_conflict: :nothing)
    Logger.info("PhoenixFlags: seeded #{count} new flag(s) (#{length(rows)} declared)")
    true
  end

  defp update_metadata(config, declared, existing) do
    updates =
      for seed <- declared,
          %Entry{} = entry <- [existing[seed.key]],
          changes = changes(config, seed, entry),
          changes != %{},
          do: {entry, changes}

    updates != [] and apply_updates(config, updates)
  end

  defp changes(config, seed, entry) do
    type = Map.get(seed, :type, "string")

    %{}
    |> change(:label, entry.label, Map.get(seed, :label, seed.key))
    |> change(:description, entry.description, Map.get(seed, :description))
    |> change(:category, entry.category, Map.get(seed, :category, "default"))
    |> change(:type, entry.type, type)
    |> Map.merge(value_reset(config, seed, entry, type))
  end

  defp value_reset(config, seed, entry, type) do
    cond do
      entry.type != type and not survives_retype?(config, seed, entry) ->
        %{value: Map.get(seed, :value, "")}

      variant_set_changed?(seed, entry) ->
        Logger.warning(
          "PhoenixFlags: #{inspect(seed.key)} declares a different set of variants than is stored " <>
            "(#{inspect(entry.value)} -> #{inspect(seed.value)}); resetting the " <>
            "split. Any runtime rollout percentages for this flag are lost."
        )

        %{value: seed.value}

      true ->
        %{}
    end
  end

  defp apply_updates(config, updates) do
    result =
      config.repo.transaction(fn ->
        Enum.each(updates, fn {entry, changes} ->
          entry |> Ecto.Changeset.change(changes) |> config.repo.update!()

          Logger.info(
            "PhoenixFlags: updated metadata for #{entry.key}: #{inspect(Map.keys(changes))}"
          )
        end)
      end)

    case result do
      {:ok, _} ->
        true

      {:error, reason} ->
        Logger.warning("PhoenixFlags: failed to update flag metadata: #{inspect(reason)}")
        false
    end
  end

  defp change(changes, _field, same, same), do: changes
  defp change(changes, field, _old, new), do: Map.put(changes, field, new)

  # A type change keeps the stored value when it is still valid for the new
  # type, so a rolling deploy flipping the type back and forth does not reset a
  # value both types accept. A secret on either side always resets: ciphertext
  # is not a value, and a plaintext value must not be read as ciphertext.
  defp survives_retype?(_config, %{type: "secret"}, _entry), do: false
  defp survives_retype?(_config, _seed, %Entry{type: "secret"}), do: false
  defp survives_retype?(_config, _seed, %Entry{value: nil}), do: false

  defp survives_retype?(config, %{type: type, key: key}, %Entry{value: value}) do
    Store.changeset(config, %Entry{key: key, type: type}, %{"value" => value}).valid?
  end

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
  defp variant_set_changed?(%{type: "variant", value: declared}, entry) do
    variant_name_set(declared) != variant_name_set(entry.value)
  end

  defp variant_set_changed?(_seed, _entry), do: false

  defp variant_name_set(value) when is_binary(value) do
    case PhoenixFlags.Variant.parse_weights(value) do
      {:ok, weights} -> weights |> Enum.map(&elem(&1, 0)) |> Enum.sort()
      # Unparseable stored values must also be reset, so give them a set no
      # declaration can equal.
      {:error, _message} -> :unparseable
    end
  end

  defp variant_name_set(_value), do: :unparseable

  defp log_undeclared(existing, declared) do
    declared_keys = MapSet.new(declared, & &1.key)

    case existing
         |> Map.keys()
         |> Enum.reject(&MapSet.member?(declared_keys, &1))
         |> Enum.sort() do
      [] ->
        :ok

      undeclared ->
        Logger.info(
          "PhoenixFlags: #{length(undeclared)} stored flag(s) are not declared and were kept: " <>
            "#{Enum.join(undeclared, ", ")}. prune_undeclared/0 deletes them."
        )
    end
  end

  # The rules table arrives with migration V4; an app that has not run it has
  # no rules to delete.
  defp delete_rules(config, keys) do
    config.repo.delete_all(from(t in PhoenixFlags.Target, where: t.key in ^keys))
  rescue
    error ->
      Logger.warning("PhoenixFlags: could not delete targeting rules: #{inspect(error)}")
  end
end
