defmodule PhoenixFlags.Targeting do
  @moduledoc false

  # Targeting rules as the rest of the library uses them: persisted and
  # validated against the flag they force, loaded for a read, and resolved.
  # What a rule *is* and how one matches a context is PhoenixFlags.Target.

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
    with {:ok, entry} <- Store.fetch(config, key),
         attrs = rule_attrs(config, key, attrs),
         %{valid?: true} = changeset <- rule_changeset(config, entry, attrs),
         {:ok, target} <- config.repo.insert(changeset) do
      {:ok, config.repo.preload(target, :conditions)}
    else
      %Ecto.Changeset{} = changeset -> {:error, changeset}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Deletes a rule by id, returning it with its conditions. The caller refreshes
  the cache. An id that is not a UUID is `:not_found`; a database that cannot
  be reached is `:unavailable`, not a missing rule.
  """
  def delete(%Config{} = config, target_id) do
    with {:ok, id} <- Ecto.UUID.cast(target_id),
         %Target{} = target <- config.repo.get(Target, id) do
      target = config.repo.preload(target, :conditions)
      config.repo.delete(target)
    else
      _missing -> {:error, :not_found}
    end
  rescue
    error ->
      Logger.warning(
        "PhoenixFlags: failed to delete target #{inspect(target_id)}: #{inspect(error.__struct__)}"
      )

      {:error, :unavailable}
  end

  @doc "A rule in words, for the audit log: `company_id in 1, 2 -> true`."
  def describe(%Target{conditions: conditions, value: value}) when is_list(conditions) do
    conditions
    |> Enum.map_join(" and ", &"#{&1.attribute} #{&1.operator} #{Enum.join(&1.values, ", ")}")
    |> Kernel.<>(" -> #{value}")
  end

  @doc """
  Every loadable rule, keyed by flag as `{type, rules}`, for the cache. The
  type is needed to cast a matching rule's value, and holding it here means a
  read does not scan the entries for it.

  A rule is not loaded for a flag with no row, nor when the flag no longer
  accepts its value -- after a type change, or once its variant or option is no
  longer declared. It stays in the table, so a rollback brings it back.
  """
  def load(%Config{} = config, entries) do
    by_key = Map.new(entries, &{&1.key, &1})

    from(t in Target, order_by: [asc: t.key, asc: t.position], preload: :conditions)
    |> config.repo.all()
    |> Enum.group_by(& &1.key)
    |> Enum.reduce(%{}, fn {key, rules}, acc ->
      case Map.fetch(by_key, key) do
        {:ok, entry} -> put_loadable(acc, config, entry, rules)
        :error -> acc
      end
    end)
  end

  @doc "One flag's loadable rules as `{type, rules}`, read from the table, or nil."
  def load_for(%Config{} = config, key) do
    with {:ok, entry} <- Store.fetch(config, key),
         [_ | _] = rules <- list(config, key),
         [_ | _] = loadable <- loadable(config, entry, rules) do
      {entry.type, loadable}
    else
      _none -> nil
    end
  rescue
    DBConnection.OwnershipError -> nil
  end

  @doc """
  `{:ok, value, type}` for the first rule in `found` matching the context, the
  value cast to the flag's type, or `:none`. `context` is a zero-arity function,
  called only once there are rules, so a flag without any never reads it.
  Never raises.
  """
  def resolve(nil, _key, _context), do: :none

  def resolve({type, rules}, key, context) do
    case resolve_with(rules, context.()) do
      {:ok, value} -> {:ok, value, type}
      :none -> :none
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
  defp resolve_with(_rules, context) when map_size(context) == 0, do: :none

  # Values were cast when the rules loaded, so a match is returned as it is.
  defp resolve_with(rules, context), do: Target.resolve(rules, context)

  defp put_loadable(acc, config, entry, rules) do
    case loadable(config, entry, Enum.sort_by(rules, & &1.position)) do
      [] -> acc
      loadable -> Map.put(acc, entry.key, {entry.type, loadable})
    end
  end

  defp loadable(config, entry, rules) do
    {valid, invalid} = Enum.split_with(rules, &valid_value?(config, entry, &1.value))

    if invalid != [] do
      Logger.warning(
        "PhoenixFlags: #{length(invalid)} targeting rule(s) for #{inspect(entry.key)} force a " <>
          "value the flag no longer accepts and are ignored: " <>
          Enum.map_join(invalid, "; ", &describe/1)
      )
    end

    Enum.map(valid, &cast_value(&1, entry.type))
  end

  # Cast once, here, rather than on every read. A :variant rule names a variant,
  # which variant/4 returns as-is; casting it as a split would fail.
  defp cast_value(rule, "variant"), do: rule
  defp cast_value(rule, type), do: %{rule | value: Entry.cast_value(rule.value, type)}

  defp valid_value?(config, entry, value) do
    Ecto.Changeset.change(%Target{value: value})
    |> validate_value(config, entry)
    |> Map.get(:valid?)
  end

  defp rule_changeset(config, entry, attrs) do
    %Target{} |> Target.changeset(attrs) |> validate_value(config, entry)
  end

  # Attrs arrive with atom keys from Elixir callers and string keys from a form.
  # Mixing the two makes cast/3 raise, so the key and position are added in
  # whichever the caller used -- and the position is only counted when missing.
  defp rule_attrs(config, key, attrs) do
    attrs = attrs |> Map.new() |> normalise_conditions()

    {key_field, position_field} =
      if string_keyed?(attrs), do: {"key", "position"}, else: {:key, :position}

    attrs
    |> Map.put(key_field, key)
    |> Map.put_new_lazy(position_field, fn -> next_position(config, key) end)
  end

  defp string_keyed?(attrs), do: Enum.any?(Map.keys(attrs), &is_binary/1)

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
