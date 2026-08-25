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
  - `:type` (required) — one of `:boolean`, `:string`, `:integer`, `:decimal`, `:percentage`, `:select`, `:secret`.
    Stored as atoms in declarations, converted to strings (`"boolean"`, etc.) for database storage.
    `:secret` values are encrypted at rest via the config's `:encryptor` module and masked in the
    admin UI and audit log. Declaring a `:secret` flag without configuring `:encryptor` raises at boot.
  - `:default` — default value as a string (defaults to `""`)
  - `:category` — grouping key for the admin UI (defaults to `"default"`)
  - `:label` — display name (defaults to the key)
  - `:description` — help text for the admin UI
  - `:options` — for `:select` type, a list of `{label, value}` tuples (e.g. `[{"Mailjet", "mailjet"}]`)
  - `:variants` (required for `:variant`) — a list of `{label, value, weight}` tuples whose
    weights are whole numbers totalling 100 (e.g. `[{"Control", "control", 90}, {"New", "new", 10}]`).
    The declared weights become the flag's initial stored value and can then be changed at
    runtime from the dashboard.
  - `:ttl` — for `:variant`, how long an assignment lasts in milliseconds. `nil` (the default)
    means an assignment is permanent. A value re-rolls each caller once per window.
  - `:seed` — for `:variant`, an explicit hash seed. Without one the split is local to this
    flag, so concurrent experiments do not correlate. Changing it re-randomises everyone.

  See `PhoenixFlags.Variant` for how assignment works.
  """

  @enforce_keys [:key, :type]
  defstruct [
    :key,
    :type,
    :description,
    :options,
    :variants,
    :ttl,
    :seed,
    default: "",
    category: "default",
    label: nil
  ]

  @valid_types PhoenixFlags.Type.valid_types()

  @type t :: %__MODULE__{
          key: String.t(),
          type: atom(),
          default: String.t(),
          category: String.t(),
          label: String.t() | nil,
          description: String.t() | nil,
          options: [{String.t(), String.t()}] | nil,
          variants: [{String.t(), String.t(), non_neg_integer()}] | nil,
          ttl: pos_integer() | nil,
          seed: String.t() | nil
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
        e in ArgumentError ->
          reraise PhoenixFlags.Error, Exception.message(e), __STACKTRACE__
      end

    validate_key!(flag.key)
    validate_type!(flag.type)
    validate_options!(flag.type, flag.options)
    validate_variants!(flag.type, flag.variants)
    validate_ttl!(flag.ttl)
    validate_seed!(flag.seed)
    validate_default!(flag.type, flag.default, flag.options)

    flag
  end

  @doc """
  Returns the `{name, weight}` pairs declared for a `:variant` flag, or `[]`.
  """
  def weights(%__MODULE__{type: :variant, variants: variants}) when is_list(variants) do
    Enum.map(variants, fn {_label, value, weight} -> {value, weight} end)
  end

  def weights(%__MODULE__{}), do: []

  defp validate_key!(key) when is_binary(key) and byte_size(key) > 0, do: :ok

  defp validate_key!(key) do
    raise PhoenixFlags.Error,
          "PhoenixFlags.Flag :key must be a non-empty string, got: #{inspect(key)}"
  end

  defp validate_type!(type) when type in @valid_types, do: :ok

  defp validate_type!(type) do
    raise PhoenixFlags.Error,
          "PhoenixFlags.Flag :type must be one of #{inspect(@valid_types)}, got: #{inspect(type)}"
  end

  defp validate_options!(:select, nil) do
    raise PhoenixFlags.Error,
          "PhoenixFlags.Flag :options is required for :select type (e.g. options: [{\"Label\", \"value\"}])"
  end

  defp validate_options!(:select, options) when is_list(options) do
    unless Enum.all?(options, &match?({_, _}, &1)) do
      raise PhoenixFlags.Error,
            "PhoenixFlags.Flag :options must be a list of {label, value} tuples, got: #{inspect(options)}"
    end
  end

  defp validate_options!(_type, _options), do: :ok

  defp validate_variants!(:variant, nil) do
    raise PhoenixFlags.Error,
          "PhoenixFlags.Flag :variants is required for :variant type " <>
            "(e.g. variants: [{\"Control\", \"control\", 50}, {\"New\", \"new\", 50}])"
  end

  defp validate_variants!(:variant, variants) when is_list(variants) do
    unless variants != [] and
             Enum.all?(
               variants,
               &match?(
                 {label, value, weight}
                 when is_binary(label) and is_binary(value) and
                        is_integer(weight) and weight >= 0,
                 &1
               )
             ) do
      raise PhoenixFlags.Error,
            "PhoenixFlags.Flag :variants must be a non-empty list of " <>
              "{label, value, weight} tuples with non-negative integer weights, " <>
              "got: #{inspect(variants)}"
    end

    # Reuse the runtime parser so a declaration and a dashboard edit can never
    # disagree about what a valid split is.
    weights = Enum.map(variants, fn {_label, value, weight} -> {value, weight} end)

    case PhoenixFlags.Variant.parse(PhoenixFlags.Variant.serialize(weights)) do
      {:ok, _variant} ->
        :ok

      {:error, message} ->
        raise PhoenixFlags.Error, "PhoenixFlags.Flag :variants #{message}"
    end
  end

  defp validate_variants!(_type, nil), do: :ok

  defp validate_variants!(type, _variants) do
    raise PhoenixFlags.Error,
          "PhoenixFlags.Flag :variants is only valid for :variant type, got type: :#{type}"
  end

  # Mirrors PhoenixFlags.Config.validate_refresh_interval!/1 — nil (infinite) or
  # a positive number of milliseconds.
  defp validate_ttl!(nil), do: :ok
  defp validate_ttl!(ttl) when is_integer(ttl) and ttl > 0, do: :ok

  defp validate_ttl!(ttl) do
    raise PhoenixFlags.Error,
          "PhoenixFlags.Flag :ttl must be a positive integer (milliseconds) or nil " <>
            "for an assignment that never expires, got: #{inspect(ttl)}"
  end

  defp validate_seed!(nil), do: :ok
  defp validate_seed!(seed) when is_binary(seed) and seed != "", do: :ok

  defp validate_seed!(seed) do
    raise PhoenixFlags.Error,
          "PhoenixFlags.Flag :seed must be a non-empty string or nil, got: #{inspect(seed)}"
  end

  # A :variant flag's stored value is its weights, built by to_seed_map/1, so
  # :default plays no part and must not be required.
  defp validate_default!(:variant, _value, _options), do: :ok

  defp validate_default!(type, "", _options) when type in [:integer, :decimal, :percentage] do
    raise PhoenixFlags.Error,
          "PhoenixFlags.Flag :default is required for :#{type} flags (e.g. default: \"0\")"
  end

  defp validate_default!(:select, value, options) do
    allowed = Enum.map(options || [], &elem(&1, 1))

    unless value in allowed do
      raise PhoenixFlags.Error,
            "PhoenixFlags.Flag default #{inspect(value)} is not in :options #{inspect(allowed)}"
    end
  end

  defp validate_default!(type, value, _options) do
    case PhoenixFlags.Type.validate_value(Atom.to_string(type), value) do
      :ok ->
        :ok

      {:error, message} ->
        raise PhoenixFlags.Error,
              "PhoenixFlags.Flag default for :#{type} #{message}, got: #{inspect(value)}"
    end
  end

  @doc false
  def to_seed_map(%__MODULE__{type: :variant} = flag) do
    %{
      key: flag.key,
      type: "variant",
      value: PhoenixFlags.Variant.serialize(weights(flag)),
      category: flag.category,
      label: flag.label || flag.key,
      description: flag.description
    }
  end

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

  # Pass-through for pre-built seed maps (used in tests)
  def to_seed_map(%{key: _, type: _, value: _} = map), do: map
end
