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
  | `select`     | `"ses"`         | `"ses"`              | must be a declared option     |
  | `secret`     | ciphertext      | decrypted plaintext  | none (encrypted at rest)      |
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

  `:secret` entries accept `""` as a way to clear the stored value; for every
  other type, `""` is still treated as missing.

  ## Options

    * `:select_options` — the `{label, value}` tuples declared for a `:select`
      flag. When given, the new value must be one of them. Callers that do not
      have the declaration at hand (e.g. building an empty form) can omit it,
      in which case no membership check runs.
  """
  def changeset(entry, attrs, opts \\ []) do
    secret? = entry.type == "secret"
    empty_values = if secret?, do: [], else: [""]

    entry
    |> cast(attrs, [:value], empty_values: empty_values)
    |> maybe_validate_required(secret?)
    |> validate_by_type()
    |> validate_select_option(Keyword.get(opts, :select_options, []))
  end

  defp maybe_validate_required(changeset, true = _secret?), do: changeset
  defp maybe_validate_required(changeset, false), do: validate_required(changeset, [:value])

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

  # The declared options are the whole point of the `:select` type, and they are
  # already enforced on the declared default at compile time (see
  # `PhoenixFlags.Flag`). Nothing constrains what actually arrives here though:
  # LiveView event params are client-controlled, so the rendered `<select>` is
  # not a validation boundary. Without this check an out-of-range value is
  # stored, cached, and handed back by `get/2`, crashing consumers that pattern
  # match on the known options.
  defp validate_select_option(changeset, []), do: changeset

  defp validate_select_option(changeset, select_options) do
    value = get_field(changeset, :value)

    if get_field(changeset, :type) == "select" and not is_nil(value) do
      allowed = Enum.map(select_options, &elem(&1, 1))

      if value in allowed do
        changeset
      else
        add_error(changeset, :value, "must be one of: #{Enum.join(allowed, ", ")}")
      end
    else
      changeset
    end
  end

  @doc """
  Casts a stored string value to its native Elixir type.
  """
  def cast_value(nil, _type), do: nil
  def cast_value("true", "boolean"), do: true
  def cast_value("false", "boolean"), do: false

  # `changeset/3` only ever stores "true" or "false", so anything else came from
  # outside the library (a hand-edited row, a data migration). The other casts
  # warn and fall back rather than failing silently; do the same here. The
  # fallback stays `false` on purpose — for a boolean flag, failing closed beats
  # returning `nil` and changing what `get(key) == false` means.
  def cast_value(value, "boolean") do
    Logger.warning("PhoenixFlags: failed to cast #{inspect(value)} as boolean, using false")
    false
  end

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
