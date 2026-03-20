defmodule PhoenixFlags.ConnCase do
  @moduledoc false
  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest

      alias PhoenixFlags.TestConfig
      alias PhoenixFlags.TestRepo

      @endpoint PhoenixFlags.TestEndpoint
    end
  end

  setup tags do
    pid = Sandbox.start_owner!(PhoenixFlags.TestRepo, shared: not tags[:async])

    on_exit(fn -> Sandbox.stop_owner(pid) end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
