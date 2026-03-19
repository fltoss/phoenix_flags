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
  - `:type` (required) — one of `:boolean`, `:string`, `:integer`, `:decimal`, `:percentage`, `:select`.
    Stored as atoms in declarations, converted to strings (`"boolean"`, etc.) for database storage.
  - `:default` — default value as a string (defaults to `""`)
  - `:category` — grouping key for the admin UI (defaults to `"default"`)
  - `:label` — display name (defaults to the key)
  - `:description` — help text for the admin UI
  """

  @enforce_keys [:key, :type]
  defstruct [:key, :type, :description, default: "", category: "default", label: nil]

  @valid_types PhoenixFlags.Type.valid_types()

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

  Raises `PhoenixFlags.Error` on invalid input.
  """
  def new!(opts) when is_list(opts) do
    flag =
      try do
        struct!(__MODULE__, opts)
      rescue
        e in ArgumentError -> raise PhoenixFlags.Error, Exception.message(e)
      end

    validate_key!(flag.key)
    validate_type!(flag.type)
    validate_default!(flag.type, flag.default)

    flag
  end

  defp validate_key!(key) when is_binary(key) and byte_size(key) > 0, do: :ok

  defp validate_key!(key) do
    raise PhoenixFlags.Error, "PhoenixFlags.Flag :key must be a non-empty string, got: #{inspect(key)}"
  end

  defp validate_type!(type) when type in @valid_types, do: :ok

  defp validate_type!(type) do
    raise PhoenixFlags.Error,
          "PhoenixFlags.Flag :type must be one of #{inspect(@valid_types)}, got: #{inspect(type)}"
  end

  defp validate_default!(type, "") when type in [:integer, :decimal, :percentage] do
    raise PhoenixFlags.Error,
          "PhoenixFlags.Flag :default is required for :#{type} flags (e.g. default: \"0\")"
  end

  defp validate_default!(type, value) do
    case PhoenixFlags.Type.validate_value(Atom.to_string(type), value) do
      :ok -> :ok
      {:error, message} -> raise PhoenixFlags.Error, "PhoenixFlags.Flag default for :#{type} #{message}, got: #{inspect(value)}"
    end
  end

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

  def to_seed_map(%{key: _} = map), do: map
end
