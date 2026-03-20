defmodule PhoenixFlags.Entry do
  @moduledoc """
  Ecto schema for a system configuration entry.

  All values are stored as strings and cast to their native type on cache load.

  ## Supported Types

  | Type         | Stored as       | Cast to              | Validation                    |
  |--------------|-----------------|----------------------|-------------------------------|
  | `string`     | `"hello"`       | `"hello"`            | none                          |
  | `boolean`    | `"true"`        | `true`               | must be `"true"` or `"false"` |
  | `integer`    | `"42"`          | `42`                 | must parse as integer         |
  | `decimal`    | `"3000"`        | `Decimal.new("3000")`| must parse as decimal         |
  | `percentage` | `"50"`          | `Decimal.new("50")`  | 0..100                        |
  | `select`     | `"ses"`         | `"ses"`              | none (app-defined)            |
  """

  use Ecto.Schema

  import Ecto.Changeset

  require Logger

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "system_flags" do
    field(:key, :string)
    field(:value, :string)
    field(:type, :string)
    field(:category, :string)
    field(:label, :string)
    field(:description, :string)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for updating an entry's value. Only `:value` is writable.
  """
  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:value])
    |> validate_required([:value])
    |> validate_by_type()
  end

  defp validate_by_type(changeset) do
    type = get_field(changeset, :type)
    value = get_field(changeset, :value)

    if is_nil(value) do
      changeset
    else
      case PhoenixFlags.Type.validate_value(type, value) do
        :ok -> changeset
        {:error, message} -> add_error(changeset, :value, message)
      end
    end
  end

  @doc """
  Casts a stored string value to its native Elixir type.
  """
  def cast_value(nil, _type), do: nil
  def cast_value(value, "boolean"), do: value == "true"

  def cast_value(value, "integer") do
    case Integer.parse(value) do
      {integer, ""} ->
        integer

      _ ->
        Logger.warning("PhoenixFlags: failed to cast #{inspect(value)} as integer")
        nil
    end
  end

  def cast_value(value, type) when type in ["decimal", "percentage"] do
    case Decimal.parse(value) do
      {decimal, ""} ->
        decimal

      _ ->
        Logger.warning("PhoenixFlags: failed to cast #{inspect(value)} as #{type}")
        nil
    end
  end

  def cast_value(value, _type), do: value
end
