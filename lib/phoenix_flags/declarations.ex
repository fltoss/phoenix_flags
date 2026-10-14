defmodule PhoenixFlags.Declarations do
  @moduledoc false

  # What a config module declares, asked by key. A module built by
  # `use PhoenixFlags` answers from a map built at compile time; a module that
  # only exports flags/0 (allowed, and used by tests with seed maps) is
  # scanned. Either way the question is asked here and nowhere else.

  alias PhoenixFlags.Flag

  @doc "Every declared flag, in declaration order."
  def all(name) do
    if exported?(name, :flags, 0), do: name.flags(), else: []
  end

  @doc "The declaration for `key`, or nil."
  def find(name, key) do
    if exported?(name, :__flag__, 1) do
      name.__flag__(key)
    else
      Enum.find(all(name), &match?(%{key: ^key}, &1))
    end
  end

  @doc "The set of declared keys."
  def keys(name), do: MapSet.new(all(name), & &1.key)

  @doc "Each declared key's position, for sorting the dashboard."
  def order(name) do
    name |> all() |> Enum.with_index() |> Map.new(fn {flag, index} -> {flag.key, index} end)
  end

  @doc "The `{label, value}` options of a `:select` flag, or `[]`."
  def select_options(name, key) do
    case find(name, key) do
      %Flag{options: options} when is_list(options) -> options
      _other -> []
    end
  end

  @doc "The declared variant names of a `:variant` flag, or `[]`."
  def variant_names(name, key) do
    case variant(name, key) do
      %Flag{} = flag -> flag |> Flag.weights() |> Enum.map(&elem(&1, 0))
      nil -> []
    end
  end

  @doc "The declaration of a `:variant` flag, or nil."
  def variant(name, key) do
    case find(name, key) do
      %Flag{type: :variant} = flag -> flag
      _other -> nil
    end
  end

  @doc "Whether any declared flag is a `:secret`."
  def any_secret?(name), do: Enum.any?(all(name), &(&1.type in [:secret, "secret"]))

  defp exported?(module, function, arity) do
    Code.ensure_loaded?(module) and function_exported?(module, function, arity)
  end
end
