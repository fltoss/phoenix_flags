defmodule PhoenixFlags.ServerTest do
  use PhoenixFlags.DataCase

  alias PhoenixFlags.Entry

  setup do
    config = %PhoenixFlags.Config{
      otp_app: :phoenix_flags,
      repo: TestRepo,
      name: TestConfig,
      cache_enabled: false
    }

    :persistent_term.put({PhoenixFlags, TestConfig, :config}, config)

    :ok
  end

  describe "get/3 with process overrides" do
    test "returns default when key does not exist" do
      assert TestConfig.get("nonexistent", "fallback") == "fallback"
    end

    test "returns process override when set" do
      TestConfig.Test.put_override("test_key", 42)

      assert TestConfig.get("test_key") == 42
    end

    test "process override takes precedence over DB" do
      TestRepo.insert!(%Entry{
        key: "override_test",
        value: "false",
        type: "boolean",
        category: "test",
        label: "Override Test"
      })

      TestConfig.Test.put_override("override_test", true)

      assert TestConfig.get("override_test") == true
    end
  end

  describe "get/3 with DB fallback" do
    test "reads boolean from DB" do
      TestRepo.insert!(%Entry{
        key: "db_bool",
        value: "true",
        type: "boolean",
        category: "test",
        label: "DB Bool"
      })

      assert TestConfig.get("db_bool") == true
    end

    test "reads integer from DB" do
      TestRepo.insert!(%Entry{
        key: "db_int",
        value: "42",
        type: "integer",
        category: "test",
        label: "DB Int"
      })

      assert TestConfig.get("db_int") == 42
    end

    test "reads decimal from DB" do
      TestRepo.insert!(%Entry{
        key: "db_dec",
        value: "3000.50",
        type: "decimal",
        category: "test",
        label: "DB Dec"
      })

      assert TestConfig.get("db_dec") == Decimal.new("3000.50")
    end

    test "reads string from DB" do
      TestRepo.insert!(%Entry{
        key: "db_str",
        value: "hello",
        type: "string",
        category: "test",
        label: "DB Str"
      })

      assert TestConfig.get("db_str") == "hello"
    end
  end

  describe "update_entry/2" do
    test "updates an existing entry" do
      TestRepo.insert!(%Entry{
        key: "updatable",
        value: "false",
        type: "boolean",
        category: "test",
        label: "Updatable"
      })

      assert {:ok, entry} = TestConfig.update_entry("updatable", %{"value" => "true"})
      assert entry.value == "true"
    end

    test "returns error for non-existent key" do
      assert {:error, :not_found} = TestConfig.update_entry("missing", %{"value" => "x"})
    end

    test "validates boolean values" do
      TestRepo.insert!(%Entry{
        key: "bool_val",
        value: "false",
        type: "boolean",
        category: "test",
        label: "Bool Val"
      })

      assert {:error, changeset} = TestConfig.update_entry("bool_val", %{"value" => "invalid"})
      assert %{value: ["must be true or false"]} = errors_on(changeset)
    end

    test "validates percentage range" do
      TestRepo.insert!(%Entry{
        key: "pct_val",
        value: "50",
        type: "percentage",
        category: "test",
        label: "Pct Val"
      })

      assert {:error, changeset} = TestConfig.update_entry("pct_val", %{"value" => "150"})
      assert %{value: ["must be between 0 and 100"]} = errors_on(changeset)
    end

    test "validates integer values" do
      TestRepo.insert!(%Entry{
        key: "int_val",
        value: "5",
        type: "integer",
        category: "test",
        label: "Int Val"
      })

      assert {:error, changeset} = TestConfig.update_entry("int_val", %{"value" => "abc"})
      assert %{value: ["must be a whole number"]} = errors_on(changeset)
    end
  end

  describe "all_grouped/0" do
    test "returns entries grouped by category" do
      TestRepo.insert!(%Entry{
        key: "a1",
        value: "true",
        type: "boolean",
        category: "alpha",
        label: "A1"
      })

      TestRepo.insert!(%Entry{
        key: "b1",
        value: "42",
        type: "integer",
        category: "beta",
        label: "B1"
      })

      TestRepo.insert!(%Entry{
        key: "a2",
        value: "false",
        type: "boolean",
        category: "alpha",
        label: "A2"
      })

      grouped = TestConfig.all_grouped()

      assert [{"alpha", alpha_entries}, {"beta", beta_entries}] = grouped
      assert length(alpha_entries) == 2
      assert length(beta_entries) == 1
    end

    test "returns empty list when no entries" do
      assert [] = TestConfig.all_grouped()
    end
  end

  describe "Test submodule" do
    test "put_override sets process-scoped value" do
      TestConfig.Test.put_override("test_flag", true)

      assert TestConfig.get("test_flag") == true
    end

    test "insert_entry inserts a DB row" do
      TestConfig.Test.insert_entry("db_flag", true)

      assert TestConfig.get("db_flag") == true
    end

    test "insert_entry upserts an existing row" do
      TestConfig.Test.insert_entry("upsert_flag", false)
      TestConfig.Test.insert_entry("upsert_flag", true)

      assert TestConfig.get("upsert_flag") == true
    end

    test "insert_entry supports custom type" do
      TestConfig.Test.insert_entry("count", 5, type: "integer")

      assert TestConfig.get("count") == 5
    end
  end

  describe "app-specific helpers" do
    test "benefits_enabled? returns false by default" do
      refute TestConfig.benefits_enabled?()
    end

    test "benefits_enabled? returns true when overridden" do
      TestConfig.Test.put_override("enable_benefits", true)

      assert TestConfig.benefits_enabled?()
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
