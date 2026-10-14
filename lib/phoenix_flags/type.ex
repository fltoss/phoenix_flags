defmodule PhoenixFlags.Type do
  @moduledoc false

  # The one place a stored string is read as its type. Validating a save and
  # casting a value on a cache load used to parse separately, and drifted: the
  # cast never checked a percentage's range, so a hand-edited "150" loaded.

  @valid_types ~w(boolean string integer decimal percentage select secret variant)a

  def valid_types, do: @valid_types

  @doc """
  Parses a stored string as `type`: `{:ok, value}` or `{:error, message}`.

  Types with no intrinsic constraint (`string`, `select`, `secret`) parse to
  themselves. A `select` value is additionally checked against its declared
  `:options`, and a `variant` value against its declared `:variants`, by
  `PhoenixFlags.Entry.changeset/3` — the only caller that knows them.
  """
  def parse(type, value)

  def parse("boolean", "true"), do: {:ok, true}
  def parse("boolean", "false"), do: {:ok, false}
  def parse("boolean", _value), do: {:error, "must be true or false"}

  def parse("integer", value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _other -> {:error, "must be a whole number"}
    end
  end

  def parse("decimal", value) when is_binary(value), do: number(value)

  def parse("percentage", value) when is_binary(value) do
    with {:ok, decimal} <- number(value) do
      if Decimal.compare(decimal, 0) != :lt and Decimal.compare(decimal, 100) != :gt do
        {:ok, decimal}
      else
        {:error, "must be between 0 and 100"}
      end
    end
  end

  # Structural only: the weights parse and total 100. Whether the names are the
  # declared ones needs the declaration, so Entry.changeset/3 does that part.
  def parse("variant", value), do: PhoenixFlags.Variant.parse(value)

  def parse(_type, value) when is_binary(value), do: {:ok, value}
  def parse(_type, _value), do: {:error, "must be a string"}

  @doc "`:ok` when `value` parses as `type`, else `{:error, message}`."
  def validate_value(type, value) do
    case parse(type, value) do
      {:ok, _value} -> :ok
      {:error, message} -> {:error, message}
    end
  end

  # Decimal.parse/1 accepts "NaN", which raises on the first comparison -- a
  # percentage's range check, or a caller's. Infinity compares, so a decimal may
  # be infinite and a percentage is refused by its range.
  defp number(value) do
    case Decimal.parse(value) do
      {%Decimal{coef: :NaN}, ""} -> {:error, "must be a valid number"}
      {decimal, ""} -> {:ok, decimal}
      _other -> {:error, "must be a valid number"}
    end
  end
end
