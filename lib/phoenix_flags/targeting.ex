defmodule PhoenixFlags.Targeting do
  @moduledoc false

  # Targeting rules as the rest of the library uses them: persisted and
  # validated against the flag they force, built into the map the cache holds,
  # and resolved on a read. What a rule *is* and how one matches a context is
  # PhoenixFlags.Target.

  import Ecto.Query

  alias PhoenixFlags.Config
  alias PhoenixFlags.Declarations
  alias PhoenixFlags.Entry
  alias PhoenixFlags.Store
  alias PhoenixFlags.Target

  require Logger

  @doc "A flag's rules, in evaluation order."
  def list(%Config{} = config, key) when is_binary(key) do
    config.repo.all(
      from(t in Target, where: t.key == ^key, order_by: [asc: t.position], preload: :conditions)
    )
  rescue
    error ->
      Logger.warning(
        "PhoenixFlags: failed to read targeting rules for #{inspect(key)}: #{inspect(error)}"
      )

      []
  end

  def list(_config, _key), do: []

  @doc "Validates and inserts a rule. The caller refreshes the cache."
  def insert(%Config{} = config, key, attrs) do
    attrs =
      attrs
      |> Map.new()
      |> normalise_conditions()
      |> Map.put(:key, key)
      |> Map.put_new(:position, next_position(config, key))

    with {:ok, entry} <- Store.fetch(config, key),
         %{valid?: true} = changeset <- rule_changeset(config, entry, attrs),
         {:ok, target} <- config.repo.insert(changeset) do
      {:ok, config.repo.preload(target, :conditions)}
    else
      %Ecto.Changeset{} = changeset -> {:error, changeset}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Deletes a rule by id. The caller refreshes the cache."
  def delete(%Config{} = config, target_id) do
    case config.repo.get(Target, target_id) do
      nil -> {:error, :not_found}
      target -> config.repo.delete(target)
    end
  rescue
    error ->
      Logger.warning(
        "PhoenixFlags: failed to delete target #{inspect(target_id)}: #{inspect(error)}"
      )

      {:error, :not_found}
  end

  @doc """
  Every rule, keyed by flag as `{type, rules}`, for the cache. The type is
  needed to cast a matching rule's value, and holding it here means a read does
  not scan the entries for it. Rules for a flag with no row are not loaded.
  """
  def load(%Config{} = config, entries) do
    types = Map.new(entries, &{&1.key, &1.type})

    config.repo.all(
      from(t in Target, order_by: [asc: t.key, asc: t.position], preload: :conditions)
    )
    |> Enum.group_by(& &1.key)
    |> Enum.reduce(%{}, fn {key, rules}, acc ->
      case Map.fetch(types, key) do
        {:ok, type} -> Map.put(acc, key, {type, Enum.sort_by(rules, & &1.position)})
        :error -> acc
      end
    end)
  end

  @doc """
  The value the first matching rule forces, cast to the flag's type, or
  `:none`. `context` is a zero-arity function: it is only called once a rule
  exists for the flag, so a flag with no rules never reads the context.
  Never raises.
  """
  def resolve(loaded, key, context) do
    case Map.get(loaded, key) do
      {type, rules} -> resolve_with(rules, context.(), type)
      _absent -> :none
    end
  rescue
    error ->
      Logger.warning(
        "PhoenixFlags: targeting failed for #{inspect(key)}: #{Exception.message(error)}"
      )

      :none
  end

  # Every rule needs a condition and a missing attribute never matches, so an
  # empty context cannot match anything.
  defp resolve_with(_rules, context, _type) when map_size(context) == 0, do: :none

  defp resolve_with(rules, context, type) do
    case Target.resolve(rules, context) do
      # A :variant rule names a variant, which variant/4 returns as-is; casting
      # it as a split would fail. Everything else casts like a stored value.
      {:ok, value} when type == "variant" -> {:ok, value}
      {:ok, value} -> {:ok, Entry.cast_value(value, type)}
      :none -> :none
    end
  end

  defp rule_changeset(config, entry, attrs) do
    %Target{} |> Target.changeset(attrs) |> validate_value(config, entry)
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

  defp validate_value(changeset, _config, %Entry{type: "secret"}) do
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
  defp validate_value(changeset, %Config{name: name}, %Entry{type: "variant", key: key}) do
    names = Declarations.variant_names(name, key)
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
  defp validate_value(changeset, %Config{} = config, %Entry{} = entry) do
    value = Ecto.Changeset.get_field(changeset, :value)

    case Store.changeset(config, entry, %{"value" => value}) do
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

  defp next_position(%Config{} = config, key) do
    config.repo.one(
      from(t in Target, where: t.key == ^key, select: coalesce(max(t.position), -1))
    ) + 1
  end
end
