defmodule PhoenixFlags.ContextTest do
  use ExUnit.Case, async: true

  alias PhoenixFlags.Context

  defmodule User do
    defstruct [:id, :company_id]
  end

  setup do
    on_exit(&Context.clear/0)
  end

  test "put/1 and merge/1 take a struct, such as the current user" do
    :ok = Context.put(%User{id: 1, company_id: 7})
    assert Context.get() == %{id: 1, company_id: 7}

    :ok = Context.merge(%User{id: 2, company_id: 7})
    assert Context.get().id == 2
  end
end
