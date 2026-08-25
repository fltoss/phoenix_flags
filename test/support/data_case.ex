defmodule PhoenixFlags.DataCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import PhoenixFlags.DataCase, only: [errors_on: 1]

      alias PhoenixFlags.TestConfig
      alias PhoenixFlags.TestRepo
    end
  end

  @doc """
  Returns a `%{field => [message]}` map of a changeset's errors, with
  interpolation placeholders (`%{count}`) resolved.
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  setup tags do
    pid = Sandbox.start_owner!(PhoenixFlags.TestRepo, shared: not tags[:async])

    on_exit(fn -> Sandbox.stop_owner(pid) end)

    :ok
  end
end
