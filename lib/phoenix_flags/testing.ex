defmodule PhoenixFlags.Testing do
  @moduledoc """
  Test helpers for PhoenixFlags.

  ## Process-Scoped Overrides

  `put_override/3` stores a value in the process dictionary, scoped to the
  calling process. When `cache_enabled: false` (test env), `get/3` checks
  the process dictionary before falling back to the database.

  This avoids DB writes and race conditions in async tests:

      setup do
        MyApp.SystemConfig.put_test_override("enable_benefits", true)
        :ok
      end

  ## Cross-Process (LiveView) Tests

  For LiveView and integration tests where the config is read in a different
  process, insert a DB row instead. The Ecto sandbox in shared mode handles
  isolation:

      PhoenixFlags.Testing.insert_entry(MyApp.Repo, "enable_benefits", true)
  """

  @doc """
  Sets a per-process config override. Only effective when `cache_enabled: false`.
  """
  def put_override(instance, key, value) do
    Process.put({PhoenixFlags, instance, key}, value)
  end

  @doc """
  Reads a per-process override. Returns `{:ok, value}` or `:none`.
  """
  def get_override(instance, key) do
    case Process.get({PhoenixFlags, instance, key}, :__psf_not_set__) do
      :__psf_not_set__ -> :none
      value -> {:ok, value}
    end
  end

  @doc """
  Inserts or updates a system flag entry in the database.

  Use this for LiveView/integration tests where the config is read
  in a different process. The Ecto sandbox in shared mode ensures isolation.

      PhoenixFlags.Testing.insert_entry(MyApp.Repo, "enable_benefits", true)
      PhoenixFlags.Testing.insert_entry(MyApp.Repo, "max_retries", 5, type: "integer")
  """
  def insert_entry(repo, key, value, opts \\ []) do
    alias PhoenixFlags.Entry

    string_value = to_string(value)
    type = Keyword.get(opts, :type, "boolean")

    case repo.get_by(Entry, key: key) do
      nil ->
        repo.insert!(%Entry{
          key: key,
          value: string_value,
          type: type,
          category: Keyword.get(opts, :category, "default"),
          label: Keyword.get(opts, :label, key)
        })

      entry ->
        entry
        |> Ecto.Changeset.change(%{value: string_value})
        |> repo.update!()
    end
  end
end
