defmodule PhoenixFlags.Testing do
  @moduledoc """
  Test helpers for PhoenixFlags.

  ## Process-Scoped Stubs

  `stub/3` stores a value in the process dictionary, scoped to the
  calling process. When `cache_enabled: false` (test env), `get/3` checks
  the process dictionary before falling back to the database.

  This avoids DB writes and race conditions in async tests:

      setup do
        MyApp.SystemConfig.Test.stub("enable_benefits", true)
        :ok
      end

  A stub is also seen by processes the test starts with `Task` -- anything that
  records the test in `$callers` -- as Mox's expectations are.

  ## Cross-Process (LiveView) Tests

  For LiveView and integration tests where the config is read in a different
  process, insert a DB row instead. The Ecto sandbox in shared mode handles
  isolation:

      MyApp.SystemConfig.Test.insert_entry("enable_benefits", true)
  """

  alias PhoenixFlags.Cache
  alias PhoenixFlags.Declarations
  alias PhoenixFlags.Entry

  @doc """
  Sets a per-process config stub. Only effective when `cache_enabled: false`.
  """
  def stub(instance, key, value) do
    Process.put({PhoenixFlags, instance, key}, value)
  end

  @doc """
  Reads a stub set by this process or by one that started it. Returns
  `{:ok, value}` or `:none`.
  """
  def get_stub(instance, key) do
    stub_key = {PhoenixFlags, instance, key}

    case Process.get(stub_key, :__phoenix_flags_unset__) do
      :__phoenix_flags_unset__ -> find_in_callers(stub_key)
      value -> {:ok, value}
    end
  end

  defp find_in_callers(stub_key) do
    :"$callers"
    |> Process.get([])
    |> Enum.find_value(:none, fn caller ->
      with {:dictionary, dictionary} <- Process.info(caller, :dictionary),
           {^stub_key, value} <- List.keyfind(dictionary, stub_key, 0) do
        {:ok, value}
      else
        _not_here -> nil
      end
    end)
  end

  @doc """
  Inserts or updates a system flag entry in the database.

  Use this for LiveView/integration tests where the config is read
  in a different process. The Ecto sandbox in shared mode ensures isolation.

      PhoenixFlags.Testing.insert_entry(MyApp.Repo, "enable_benefits", true)
      PhoenixFlags.Testing.insert_entry(MyApp.Repo, "max_retries", 5, type: "integer")

  Given `instance:` (which the generated `Test.insert_entry/3` passes), the
  type comes from the flag's declaration, and a `:secret` value is encrypted
  with the instance's encryptor, as a real save would. Without it the type is
  inferred from the value, and a secret cannot be inserted: it would be stored
  as plaintext and then fail to decrypt.
  """
  def insert_entry(repo, key, value, opts \\ []) do
    instance = Keyword.get(opts, :instance)

    type =
      Keyword.get_lazy(opts, :type, fn -> declared_type(instance, key) || infer_type(value) end)

    stored = value |> to_string() |> encrypt_secret(type, instance)

    case repo.get_by(Entry, key: key) do
      nil ->
        repo.insert!(%Entry{
          key: key,
          value: stored,
          type: type,
          category: Keyword.get(opts, :category, "default"),
          label: Keyword.get(opts, :label, key)
        })

      entry ->
        entry
        |> Ecto.Changeset.change(%{value: stored, type: type})
        |> repo.update!()
    end
  end

  defp declared_type(nil, _key), do: nil

  defp declared_type(instance, key) do
    case Declarations.find(instance, key) do
      %{type: type} when is_atom(type) -> Atom.to_string(type)
      %{type: type} -> type
      nil -> nil
    end
  end

  defp encrypt_secret(value, "secret", instance) do
    case instance && Cache.config(instance) do
      {:ok, %{encryptor: encryptor}} when not is_nil(encryptor) ->
        encryptor.encrypt(value)

      _no_encryptor ->
        raise PhoenixFlags.Error,
              "insert_entry/4 for a :secret flag needs a running instance with an :encryptor -- " <>
                "use the generated Test.insert_entry/3 -- or the value would be stored as plaintext"
    end
  end

  defp encrypt_secret(value, _type, _instance), do: value

  defp infer_type(value) when is_boolean(value), do: "boolean"
  defp infer_type(value) when is_integer(value), do: "integer"
  defp infer_type(%Decimal{}), do: "decimal"
  defp infer_type(_), do: "string"
end
