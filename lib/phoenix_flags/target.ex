defmodule PhoenixFlags.Target do
  @moduledoc """
  A targeting rule: force a flag's value when the request context matches.

  This is what lets you turn a feature on for one customer without a deploy.
  A rule belongs to a flag, carries an ordered list of conditions that must
  **all** match, and a value to return when they do.

      MyApp.SystemConfig.put_target("enable_benefits",
        conditions: [[attribute: :company_id, operator: :in, values: [123, 456]]],
        value: "true"
      )

  Rules are evaluated in `position` order and the **first match wins**. A
  matching rule overrides both the stored value and, for a `:variant` flag, the
  weighted split — "force this for them" would not mean much otherwise.

  ## Operators

  | Operator | Matches when |
  |---|---|
  | `:in` | the context value equals any of `values` |
  | `:not_in` | the context value equals none of `values` |
  | `:eq` | the context value equals the first of `values` |
  | `:starts_with` | the context value starts with any of `values` |

  ## Comparison is by string

  Every flag value in PhoenixFlags is stored as a string, and rule values follow
  suit. Both sides of a comparison are put through `to_string/1`, so a context of
  `%{company_id: 123}` matches a rule value of `"123"`. Attribute keys are
  compared the same way, so `:company_id` and `"company_id"` are one attribute.

  If a rule never seems to fire, this is almost always why — check that the value
  you expect is what `to_string/1` produces (a `Decimal`, a struct, or a float
  will not stringify the way you might assume).

  ## A missing attribute never matches

  A rule on `company_id` does not match a context without a `company_id`. It does
  not match vacuously and it does not raise — an absent attribute simply is not a
  match, so `:not_in` on a missing attribute is `false` too.
  """

  use Ecto.Schema

  import Ecto.Changeset

  # In its own file so the struct is compiled before this module expands
  # `%Condition{}`. With it nested at the bottom, Elixir 1.16 and 1.18 failed
  # with "Condition.__struct__/1 is undefined"; 1.20 happens to tolerate it.
  alias PhoenixFlags.Target.Condition

  @operators ~w(in not_in eq starts_with)a

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "system_flag_targets" do
    field(:key, :string)
    field(:value, :string)
    field(:position, :integer, default: 0)

    has_many(:conditions, Condition,
      foreign_key: :target_id,
      on_replace: :delete,
      preload_order: [asc: :inserted_at]
    )

    timestamps(type: :utc_datetime)
  end

  @type t :: %__MODULE__{}

  @doc """
  The operators a condition may use.
  """
  @spec operators() :: [atom()]
  def operators, do: @operators

  @doc """
  Changeset for a targeting rule and its conditions.

  Validates the shape only. Whether `value` is legal *for the flag's type* is
  checked by the caller, which is the only place that knows the declaration —
  see `PhoenixFlags.Server.put_target/3`.
  """
  def changeset(target, attrs) do
    target
    |> cast(attrs, [:key, :value, :position])
    |> validate_required([:key, :value])
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> cast_assoc(:conditions, required: true, with: &Condition.changeset/2)
  end

  @doc """
  Returns the value of the first rule whose conditions all match `context`, or
  `:none`.

  Rules are assumed to arrive in `position` order — `PhoenixFlags.Server` sorts
  them once when the cache loads rather than on every read.

  Never raises: a malformed rule or context yields no match rather than taking
  down the caller, because this sits on the read path.
  """
  @spec resolve([t()], map()) :: {:ok, String.t()} | :none
  def resolve(targets, context)

  def resolve([], _context), do: :none
  def resolve(_targets, context) when not is_map(context), do: :none

  def resolve(targets, context) when is_list(targets) do
    normalised = normalise_context(context)

    case Enum.find(targets, &matches?(&1, normalised)) do
      %__MODULE__{value: value} -> {:ok, value}
      nil -> :none
    end
  end

  def resolve(_targets, _context), do: :none

  @doc """
  Whether every condition on `target` matches `context`.

  A rule with no conditions never matches — an empty condition list would
  otherwise force its value on everyone, which is never what was meant.

  `context` may be a plain map; keys and values are normalised the same way
  `resolve/2` does.
  """
  @spec matches?(t(), map()) :: boolean()
  def matches?(target, context)

  def matches?(%__MODULE__{conditions: conditions}, context) when is_list(conditions) do
    context = if normalised?(context), do: context, else: normalise_context(context)

    conditions != [] and Enum.all?(conditions, &condition_matches?(&1, context))
  end

  def matches?(_target, _context), do: false

  # Marked so resolve/2 can normalise once for the whole list instead of once per
  # rule, while matches?/2 stays safe to call on its own.
  defp normalised?(%{__phoenix_flags_normalised__: true}), do: true
  defp normalised?(_context), do: false

  defp normalise_context(context) when is_map(context) do
    context
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      case safe_to_string(key) do
        {:ok, key} -> Map.put(acc, key, safe_to_string(value))
        :error -> acc
      end
    end)
    |> Map.put(:__phoenix_flags_normalised__, true)
  end

  defp normalise_context(_context), do: %{__phoenix_flags_normalised__: true}

  defp condition_matches?(
         %Condition{attribute: attribute, operator: operator, values: values},
         ctx
       )
       when is_binary(attribute) and is_binary(operator) and is_list(values) do
    case Map.get(ctx, attribute) do
      {:ok, value} -> compare(operator, value, values)
      # Absent, or a value that cannot be stringified: not a match, including for
      # :not_in — "everyone except these" should not sweep in callers we know
      # nothing about.
      _other -> false
    end
  end

  defp condition_matches?(_condition, _context), do: false

  defp compare("in", value, values), do: value in values
  defp compare("not_in", value, values), do: value not in values
  defp compare("eq", value, [expected | _rest]), do: value == expected
  defp compare("eq", _value, []), do: false

  defp compare("starts_with", value, values),
    do: Enum.any?(values, &String.starts_with?(value, &1))

  defp compare(_operator, _value, _values), do: false

  # Context values are arbitrary terms from the caller, so String.Chars may not
  # be implemented; that must not raise on a read path.
  defp safe_to_string(term) when is_binary(term), do: {:ok, term}
  defp safe_to_string(term) when is_atom(term), do: {:ok, Atom.to_string(term)}
  defp safe_to_string(term) when is_integer(term), do: {:ok, Integer.to_string(term)}

  defp safe_to_string(term) do
    {:ok, to_string(term)}
  rescue
    Protocol.UndefinedError -> :error
  end
end
