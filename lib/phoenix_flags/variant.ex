defmodule PhoenixFlags.Variant do
  @moduledoc """
  A weighted set of variants for an A/B test, and the assignment function.

  A `:variant` flag resolves to a *different* value per caller, chosen by a
  consistent hash of an identity you supply. The same identity always gets the
  same variant, on every node and across restarts, so a user sees a stable
  experience and the results stay analysable.

  The weights live in the flag's stored value as a compact, human-editable
  string, so a rollout can be changed at runtime from the dashboard:

      "control=50,new_flow=50"

  ## Assignment

  The hash input is `seed : key : identity`, run through SHA-256, with the
  leading 64 bits taken modulo #{10_000}. The resulting point is looked up in a
  cumulative bucket table built once when the cache loads.

  SHA-256 rather than `:erlang.phash2/2` is deliberate: `phash2` is not
  guaranteed stable across OTP major versions, so an OTP upgrade would silently
  reshuffle every running experiment.

  The flag key is part of the hash input, so two concurrent experiments do not
  correlate — a user in control for one is not systematically in control for the
  other. Pass an explicit `:seed` to deliberately correlate two flags, or to
  re-randomise everyone when restarting an experiment.

  ## Stickiness

  Buckets are cumulative in declaration order, so growing a variant at the
  expense of the *next* one moves only the boundary between them: going from
  `control=90,new=10` to `control=80,new=20` moves the 80–90 band and leaves
  everyone else where they were. That property is what makes a gradual rollout
  safe.

  It does **not** survive reordering the `:variants` declaration, changing
  `:seed`, or a `:ttl` rollover. Any of those reshuffles the population.

  ## TTL

  With `ttl: nil` (the default) an assignment is permanent. A non-nil `:ttl`
  in milliseconds folds a time window into the hash, so each identity is
  re-rolled once per window. The window is offset per identity, so the
  population does not all flip at the same instant.
  """

  @resolution 10_000
  @weight_total 100

  defstruct buckets: [], weights: [], ttl: nil, seed: nil

  @type name :: String.t()
  @type weight :: non_neg_integer()

  @type t :: %__MODULE__{
          buckets: [{name(), pos_integer()}],
          weights: [{name(), weight()}],
          ttl: pos_integer() | nil,
          seed: String.t() | nil
        }

  @doc """
  Parses a stored weights string into a `%PhoenixFlags.Variant{}`.

  Returns `{:ok, variant}` or `{:error, message}`, where the message is
  end-user readable — it is surfaced as a changeset error on the dashboard.

  ## Options

    * `:ttl` — assignment lifetime in milliseconds; `nil` (default) is infinite
    * `:seed` — hash seed; `nil` (default) keeps the split local to this flag
    * `:names` — the declared variant names. When given, every name in the
      string must be one of them. Omit to skip that check (the caller may not
      have the declaration at hand).

  ## Examples

      iex> {:ok, variant} = PhoenixFlags.Variant.parse("control=60,new=40")
      iex> variant.weights
      [{"control", 60}, {"new", 40}]
      iex> variant.buckets
      [{"control", 6000}, {"new", 10000}]

      iex> PhoenixFlags.Variant.parse("control=60,new=30")
      {:error, "weights must total 100, got 90"}
  """
  @spec parse(String.t(), keyword()) :: {:ok, t()} | {:error, String.t()}
  def parse(value, opts \\ [])

  def parse(value, opts) when is_binary(value) do
    with {:ok, weights} <- do_parse_weights(value),
         :ok <- validate_total(weights),
         :ok <- validate_unique(weights),
         :ok <- validate_names(weights, Keyword.get(opts, :names)) do
      {:ok,
       %__MODULE__{
         weights: weights,
         buckets: build_buckets(weights),
         ttl: Keyword.get(opts, :ttl),
         seed: Keyword.get(opts, :seed)
       }}
    end
  end

  def parse(value, _opts) do
    {:error, "must be a string of the form \"name=50,other=50\", got: #{inspect(value)}"}
  end

  @doc """
  Parses a weights string *without* checking that it totals 100.

  The dashboard needs this to re-render inputs for a split the operator is
  midway through editing, which is invalid by definition. Prefer `parse/2`
  anywhere the result will actually be used for assignment.

  ## Examples

      iex> PhoenixFlags.Variant.parse_weights("a=30,b=30")
      {:ok, [{"a", 30}, {"b", 30}]}
  """
  @spec parse_weights(String.t()) :: {:ok, [{name(), weight()}]} | {:error, String.t()}
  def parse_weights(value) when is_binary(value), do: do_parse_weights(value)
  def parse_weights(_value), do: {:error, "must be a string"}

  @doc """
  Serialises `{name, weight}` pairs (or a `%PhoenixFlags.Variant{}`) back into
  the stored string form.

  ## Examples

      iex> PhoenixFlags.Variant.serialize([{"control", 60}, {"new", 40}])
      "control=60,new=40"
  """
  @spec serialize(t() | [{name(), weight()}]) :: String.t()
  def serialize(%__MODULE__{weights: weights}), do: serialize(weights)

  def serialize(weights) when is_list(weights) do
    Enum.map_join(weights, ",", fn {name, weight} -> "#{name}=#{weight}" end)
  end

  @doc """
  Returns the variant name assigned to `identity` for the flag `key`.

  Deterministic: the same arguments always produce the same result. Returns
  `nil` only when there are no buckets to choose from.

  Raises when `identity` is `nil` or not a binary or integer — bucketing every
  caller identically because an identity was quietly missing is a serious and
  invisible bug, so it fails loudly instead.

  ## Options

    * `:now` — current time in milliseconds, for testing TTL rollover without
      sleeping. Defaults to the system clock and is ignored when `ttl` is `nil`.
  """
  @spec assign(t(), String.t(), String.t() | integer(), keyword()) :: name() | nil
  def assign(variant, key, identity, opts \\ [])

  def assign(%__MODULE__{buckets: []}, _key, _identity, _opts), do: nil

  def assign(%__MODULE__{} = variant, key, identity, opts) when is_binary(key) do
    identity = normalise_identity(identity)

    variant
    |> bucket_point(key, identity, opts)
    |> find_bucket(variant.buckets)
  end

  @doc """
  The number of points the hash space is divided into.
  """
  @spec resolution() :: pos_integer()
  def resolution, do: @resolution

  @doc """
  The total the declared weights must sum to.
  """
  @spec weight_total() :: pos_integer()
  def weight_total, do: @weight_total

  # ============================================================================
  # Assignment
  # ============================================================================

  # With no TTL the hash input carries no time component at all, so the
  # infinite-assignment path does no clock work.
  defp bucket_point(%__MODULE__{ttl: nil, seed: seed}, key, identity, _opts) do
    hash_point([seed_part(seed), key, identity])
  end

  defp bucket_point(%__MODULE__{ttl: ttl, seed: seed}, key, identity, opts) do
    now = Keyword.get_lazy(opts, :now, fn -> System.os_time(:millisecond) end)

    hash_point([seed_part(seed), key, identity, Integer.to_string(epoch(identity, ttl, now))])
  end

  # The offset is derived from the identity alone, so each caller has its own
  # rotation phase and the whole population does not re-roll at the same instant.
  # It is deliberately independent of the flag key: a given user's window
  # boundary is then the same across every experiment they are in.
  defp epoch(identity, ttl, now) do
    offset = rem(hash_integer([identity]), ttl)

    div(now + offset, ttl)
  end

  defp seed_part(nil), do: ""
  defp seed_part(seed) when is_binary(seed), do: seed

  defp hash_point(parts), do: rem(hash_integer(parts), @resolution)

  defp hash_integer(parts) do
    <<integer::unsigned-integer-size(64), _rest::binary>> =
      :crypto.hash(:sha256, Enum.join(parts, ":"))

    integer
  end

  defp find_bucket(point, [{name, limit} | rest]) do
    if point < limit, do: name, else: find_bucket(point, rest)
  end

  # Only reachable when trailing variants have weight 0, which correctly never
  # win; the last positive-weight bucket has already matched by then.
  defp find_bucket(_point, []), do: nil

  defp normalise_identity(identity) when is_binary(identity) and identity != "", do: identity
  defp normalise_identity(identity) when is_integer(identity), do: Integer.to_string(identity)

  defp normalise_identity(identity) do
    raise PhoenixFlags.Error,
          "PhoenixFlags: variant identity must be a non-empty string or an integer, got: " <>
            "#{inspect(identity)}. A missing identity would assign every caller the same " <>
            "variant, so it is rejected rather than silently bucketed."
  end

  # ============================================================================
  # Parsing
  # ============================================================================

  defp do_parse_weights(""), do: {:error, "must not be empty (expected \"name=50,other=50\")"}

  defp do_parse_weights(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.reduce_while({:ok, []}, fn part, {:ok, acc} ->
      case parse_pair(String.trim(part)) do
        {:ok, pair} -> {:cont, {:ok, [pair | acc]}}
        {:error, message} -> {:halt, {:error, message}}
      end
    end)
    |> case do
      {:ok, []} -> {:error, "must not be empty (expected \"name=50,other=50\")"}
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      {:error, message} -> {:error, message}
    end
  end

  defp parse_pair(part) do
    case String.split(part, "=", parts: 2) do
      [name, weight] -> parse_pair(String.trim(name), String.trim(weight))
      _ -> {:error, "#{inspect(part)} is not of the form \"name=50\""}
    end
  end

  defp parse_pair("", _weight), do: {:error, "variant name must not be empty"}

  defp parse_pair(name, weight) do
    case Integer.parse(weight) do
      {integer, ""} when integer >= 0 -> {:ok, {name, integer}}
      _ -> {:error, "weight for #{inspect(name)} must be a non-negative whole number"}
    end
  end

  # Enum.sum_by/2 would read better but is Elixir 1.18+; the declared floor is
  # ~> 1.16 and CI verifies it.
  defp validate_total(weights) do
    case Enum.reduce(weights, 0, fn {_name, weight}, total -> total + weight end) do
      @weight_total -> :ok
      total -> {:error, "weights must total #{@weight_total}, got #{total}"}
    end
  end

  defp validate_unique(weights) do
    names = Enum.map(weights, &elem(&1, 0))

    case names -- Enum.uniq(names) do
      [] -> :ok
      duplicates -> {:error, "duplicate variant(s): #{Enum.join(Enum.uniq(duplicates), ", ")}"}
    end
  end

  defp validate_names(_weights, nil), do: :ok

  defp validate_names(weights, declared) do
    case Enum.map(weights, &elem(&1, 0)) -- declared do
      [] ->
        :ok

      unknown ->
        {:error,
         "unknown variant(s) #{Enum.join(unknown, ", ")}; " <>
           "declared: #{Enum.join(declared, ", ")}"}
    end
  end

  defp build_buckets(weights) do
    {buckets, _total} =
      Enum.map_reduce(weights, 0, fn {name, weight}, cumulative ->
        cumulative = cumulative + weight * div(@resolution, @weight_total)

        {{name, cumulative}, cumulative}
      end)

    buckets
  end
end
