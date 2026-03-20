defmodule PhoenixFlags.FakeRepo do
  @moduledoc false
  # A fake repo that raises on all operations, simulating a DB connection failure.

  def all(_queryable), do: raise(DBConnection.ConnectionError, "connection refused")
  def get_by(_queryable, _clauses), do: raise(DBConnection.ConnectionError, "connection refused")

  def insert_all(_schema, _entries, _opts \\ []),
    do: raise(DBConnection.ConnectionError, "connection refused")

  def transaction(_fun), do: raise(DBConnection.ConnectionError, "connection refused")
  def delete_all(_queryable), do: raise(DBConnection.ConnectionError, "connection refused")
  def query(_sql, _params), do: raise(DBConnection.ConnectionError, "connection refused")
end
