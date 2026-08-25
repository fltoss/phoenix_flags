defmodule PhoenixFlags.Type do
  @moduledoc false

  @valid_types ~w(boolean string integer decimal percentage select secret)a

  def valid_types, do: @valid_types

  @doc """
  Validates a string value against its type.
  Returns `:ok` or `{:error, message}`.

  Types with no intrinsic constraint (`string`, `select`, `secret`) return `:ok`.
  A `select` value is additionally checked against its declared `:options` by
  `PhoenixFlags.Entry.changeset/3`, which is the only caller that knows them.
  """
  def validate_value("boolean", value) when value in ["true", "false"], do: :ok
  def validate_value("boolean", _), do: {:error, "must be true or false"}

  def validate_value("integer", value) do
    case Integer.parse(value) do
      {_, ""} -> :ok
      _ -> {:error, "must be a whole number"}
    end
  end

  def validate_value("decimal", value) do
    case Decimal.parse(value) do
      {_, ""} -> :ok
      _ -> {:error, "must be a valid number"}
    end
  end

  def validate_value("percentage", value) do
    case Decimal.parse(value) do
      {decimal, ""} ->
        if Decimal.compare(decimal, 0) in [:gt, :eq] and
             Decimal.compare(decimal, 100) in [:lt, :eq] do
          :ok
        else
          {:error, "must be between 0 and 100"}
        end

      _ ->
        {:error, "must be a valid number"}
    end
  end

  def validate_value(_type, _value), do: :ok
end
