defmodule PhoenixFlags.Flag do
  @moduledoc """
  Struct defining a flag declaration.

  Used in the `flags/0` callback to declare which flags should exist:

      def flags do
        [
          PhoenixFlags.Flag.new!(
            key: "enable_benefits",
            type: :boolean,
            default: "false",
            category: "integrations",
            label: "Enable Benefits",
            description: "When enabled, the Benefits integration is active."
          )
        ]
      end

  ## Fields

  - `:key` (required) — unique identifier for this flag
  - `:type` (required) — one of `:boolean`, `:string`, `:integer`, `:decimal`, `:percentage`, `:select`
  - `:default` — default value as a string (defaults to `""`)
  - `:category` — grouping key for the admin UI (defaults to `"default"`)
  - `:label` — display name (defaults to the key)
  - `:description` — help text for the admin UI
  """

  @enforce_keys [:key, :type]
  defstruct [:key, :type, :description, default: "", category: "default", label: nil]

  @valid_types ~w(boolean string integer decimal percentage select)a

  @type t :: %__MODULE__{
          key: String.t(),
          type: atom(),
          default: String.t(),
          category: String.t(),
          label: String.t() | nil,
          description: String.t() | nil
        }

  @doc """
  Creates a new flag struct, validating all fields.

  Raises `ArgumentError` on invalid input.
  """
  def new!(opts) when is_list(opts) do
    flag = struct!(__MODULE__, opts)

    validate_key!(flag.key)
    validate_type!(flag.type)
    validate_default!(flag.type, flag.default)

    flag
  end

  defp validate_key!(key) when is_binary(key) and byte_size(key) > 0, do: :ok

  defp validate_key!(key) do
    raise ArgumentError, "PhoenixFlags.Flag :key must be a non-empty string, got: #{inspect(key)}"
  end

  defp validate_type!(type) when type in @valid_types, do: :ok

  defp validate_type!(type) do
    raise ArgumentError,
          "PhoenixFlags.Flag :type must be one of #{inspect(@valid_types)}, got: #{inspect(type)}"
  end

  defp validate_default!(:boolean, value) when value in ["true", "false"], do: :ok

  defp validate_default!(:boolean, value) do
    raise ArgumentError,
          "PhoenixFlags.Flag default for :boolean must be \"true\" or \"false\", got: #{inspect(value)}"
  end

  defp validate_default!(:integer, value) do
    case Integer.parse(value) do
      {_, ""} -> :ok
      _ -> raise ArgumentError, "PhoenixFlags.Flag default for :integer must be a valid integer string, got: #{inspect(value)}"
    end
  end

  defp validate_default!(:decimal, value) do
    case Decimal.parse(value) do
      {_, ""} -> :ok
      _ -> raise ArgumentError, "PhoenixFlags.Flag default for :decimal must be a valid decimal string, got: #{inspect(value)}"
    end
  end

  defp validate_default!(:percentage, value) do
    case Decimal.parse(value) do
      {decimal, ""} ->
        if Decimal.compare(decimal, 0) in [:gt, :eq] and Decimal.compare(decimal, 100) in [:lt, :eq] do
          :ok
        else
          raise ArgumentError, "PhoenixFlags.Flag default for :percentage must be between 0 and 100, got: #{inspect(value)}"
        end

      _ ->
        raise ArgumentError, "PhoenixFlags.Flag default for :percentage must be a valid number, got: #{inspect(value)}"
    end
  end

  defp validate_default!(_type, _value), do: :ok

  @doc false
  def to_seed_map(%__MODULE__{} = flag) do
    %{
      key: flag.key,
      type: Atom.to_string(flag.type),
      value: flag.default,
      category: flag.category,
      label: flag.label || flag.key,
      description: flag.description
    }
  end
end
