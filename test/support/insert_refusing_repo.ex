defmodule PhoenixFlags.InsertRefusingRepo do
  @moduledoc false
  # The test repo with INSERT refused, as a missing grant would: reads work,
  # seeding new flags does not.

  alias PhoenixFlags.TestRepo

  def insert_all(_schema, _rows, _opts),
    do: raise(Postgrex.Error, message: "permission denied for table system_flags")

  defdelegate all(queryable), to: TestRepo
  defdelegate all(queryable, opts), to: TestRepo
  defdelegate get_by(queryable, clauses), to: TestRepo
  defdelegate transaction(fun), to: TestRepo
  defdelegate one(queryable), to: TestRepo
end
