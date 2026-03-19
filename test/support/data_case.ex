defmodule PhoenixFlags.DataCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      alias PhoenixFlags.TestConfig
      alias PhoenixFlags.TestRepo
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(PhoenixFlags.TestRepo, shared: not tags[:async])

    on_exit(fn -> Sandbox.stop_owner(pid) end)

    :ok
  end
end
