defmodule PhoenixFlags.Target.Condition do
  @moduledoc """
  One condition of a `PhoenixFlags.Target`: an attribute, an operator, and the
  values to compare against.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "system_flag_target_conditions" do
    field(:attribute, :string)
    field(:operator, :string)
    field(:values, {:array, :string}, default: [])

    belongs_to(:target, PhoenixFlags.Target, type: :binary_id)

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc """
  Changeset for a condition.

  `attribute` and `values` are normalised to strings so a rule written with
  `attribute: :company_id, values: [123]` matches a context of
  `%{company_id: 123}` — see the note on string comparison in
  `PhoenixFlags.Target`.
  """
  def changeset(condition, attrs) do
    condition
    |> cast(normalise(attrs), [:attribute, :operator, :values])
    |> validate_required([:attribute, :operator])
    |> validate_inclusion(:operator, Enum.map(PhoenixFlags.Target.operators(), &to_string/1),
      message:
        "must be one of: #{Enum.map_join(PhoenixFlags.Target.operators(), ", ", &to_string/1)}"
    )
    |> validate_values_present()
    |> validate_change(:attribute, fn :attribute, attribute ->
      if String.trim(attribute) == "", do: [attribute: "must not be blank"], else: []
    end)
  end

  # `validate_length/3` only inspects *changes*, and `values: []` matches the
  # field default so it is not a change. That gap matters: `not_in []` matches
  # every caller that has the attribute at all, silently forcing the rule's
  # value on everyone. Validate the resolved field instead.
  defp validate_values_present(changeset) do
    case get_field(changeset, :values) do
      [_first | _rest] -> changeset
      _empty_or_nil -> add_error(changeset, :values, "must have at least one value")
    end
  end

  # Braces: a condition can only ever narrow, so an operator with nothing to
  # compare against is rejected rather than silently matching everyone.
  defp normalise(attrs) when is_map(attrs) do
    attrs
    |> Enum.map(fn {field, value} -> {field, normalise_field(field, value)} end)
    |> Map.new()
  end

  defp normalise(attrs), do: attrs

  defp normalise_field(field, value)
       when field in [:attribute, "attribute", :operator, "operator"] and is_atom(value) and
              not is_nil(value) and not is_boolean(value) do
    Atom.to_string(value)
  end

  defp normalise_field(field, values)
       when field in [:values, "values"] and is_list(values) do
    Enum.map(values, fn
      value when is_binary(value) -> value
      value when is_atom(value) or is_integer(value) or is_float(value) -> to_string(value)
      other -> other
    end)
  end

  defp normalise_field(_field, value), do: value
end
