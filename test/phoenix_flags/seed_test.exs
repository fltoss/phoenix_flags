defmodule PhoenixFlags.SeedTest do
  use PhoenixFlags.DataCase

  alias PhoenixFlags.Config
  alias PhoenixFlags.Entry
  alias PhoenixFlags.Server

  defp start_server!(flags) do
    # Create a dynamic module with the given flags
    module_name = :"PhoenixFlags.SeedTest.Config#{System.unique_integer([:positive])}"

    # Define the module at runtime with the given flags
    Module.create(
      module_name,
      quote do
        def flags, do: unquote(Macro.escape(flags))
      end,
      Macro.Env.location(__ENV__)
    )

    config = %Config{
      otp_app: :phoenix_flags,
      repo: TestRepo,
      name: module_name,
      cache_enabled: false
    }

    start_supervised!({Server, config})

    {module_name, config}
  end

  describe "seed_flags on startup" do
    test "inserts declared flags that don't exist" do
      {_module, _config} =
        start_server!([
          %{key: "flag_a", type: "boolean", value: "true", category: "test", label: "Flag A"},
          %{key: "flag_b", type: "integer", value: "42", category: "test", label: "Flag B"}
        ])

      assert TestRepo.get_by(Entry, key: "flag_a")
      assert TestRepo.get_by(Entry, key: "flag_b")
    end

    test "does not overwrite existing flag values" do
      # Pre-insert with a different value
      TestRepo.insert!(%Entry{
        key: "existing_flag",
        value: "true",
        type: "boolean",
        category: "test",
        label: "Existing"
      })

      {_module, _config} =
        start_server!([
          %{key: "existing_flag", type: "boolean", value: "false", category: "test", label: "Existing"}
        ])

      entry = TestRepo.get_by(Entry, key: "existing_flag")
      # Value should remain "true" (runtime value), not "false" (declared default)
      assert entry.value == "true"
    end

    test "removes flags no longer declared" do
      TestRepo.insert!(%Entry{
        key: "stale_flag",
        value: "old",
        type: "string",
        category: "test",
        label: "Stale"
      })

      {_module, _config} =
        start_server!([
          %{key: "active_flag", type: "boolean", value: "true", category: "test", label: "Active"}
        ])

      refute TestRepo.get_by(Entry, key: "stale_flag")
      assert TestRepo.get_by(Entry, key: "active_flag")
    end

    test "updates metadata when label changes" do
      TestRepo.insert!(%Entry{
        key: "relabeled",
        value: "true",
        type: "boolean",
        category: "test",
        label: "Old Label",
        description: "Old desc"
      })

      {_module, _config} =
        start_server!([
          %{
            key: "relabeled",
            type: "boolean",
            value: "false",
            category: "test",
            label: "New Label",
            description: "New desc"
          }
        ])

      entry = TestRepo.get_by(Entry, key: "relabeled")
      assert entry.label == "New Label"
      assert entry.description == "New desc"
      # Value preserved — not overwritten by declared default
      assert entry.value == "true"
    end

    test "updates metadata when category changes" do
      TestRepo.insert!(%Entry{
        key: "recategorized",
        value: "42",
        type: "integer",
        category: "old_category",
        label: "Flag"
      })

      {_module, _config} =
        start_server!([
          %{key: "recategorized", type: "integer", value: "0", category: "new_category", label: "Flag"}
        ])

      entry = TestRepo.get_by(Entry, key: "recategorized")
      assert entry.category == "new_category"
      assert entry.value == "42"
    end

    test "resets value when type changes" do
      TestRepo.insert!(%Entry{
        key: "retyped",
        value: "true",
        type: "boolean",
        category: "test",
        label: "Retyped"
      })

      {_module, _config} =
        start_server!([
          %{key: "retyped", type: "integer", value: "0", category: "test", label: "Retyped"}
        ])

      entry = TestRepo.get_by(Entry, key: "retyped")
      assert entry.type == "integer"
      # Value reset because "true" is not a valid integer
      assert entry.value == "0"
    end

    test "resets value when type changes from integer to boolean" do
      TestRepo.insert!(%Entry{
        key: "int_to_bool",
        value: "42",
        type: "integer",
        category: "test",
        label: "Int to Bool"
      })

      {_module, _config} =
        start_server!([
          %{key: "int_to_bool", type: "boolean", value: "false", category: "test", label: "Int to Bool"}
        ])

      entry = TestRepo.get_by(Entry, key: "int_to_bool")
      assert entry.type == "boolean"
      assert entry.value == "false"
    end

    test "resets value when type changes from string to percentage" do
      TestRepo.insert!(%Entry{
        key: "str_to_pct",
        value: "hello",
        type: "string",
        category: "test",
        label: "Str to Pct"
      })

      {_module, _config} =
        start_server!([
          %{key: "str_to_pct", type: "percentage", value: "50", category: "test", label: "Str to Pct"}
        ])

      entry = TestRepo.get_by(Entry, key: "str_to_pct")
      assert entry.type == "percentage"
      assert entry.value == "50"
    end

    test "handles empty flags list" do
      TestRepo.insert!(%Entry{
        key: "orphan",
        value: "true",
        type: "boolean",
        category: "test",
        label: "Orphan"
      })

      {_module, _config} = start_server!([])

      # Empty flags means remove everything
      refute TestRepo.get_by(Entry, key: "orphan")
    end

    test "handles mixed operations: insert, update, and delete" do
      # Will be kept (metadata updated)
      TestRepo.insert!(%Entry{
        key: "keep_me",
        value: "original",
        type: "string",
        category: "old",
        label: "Old Label"
      })

      # Will be removed
      TestRepo.insert!(%Entry{
        key: "remove_me",
        value: "bye",
        type: "string",
        category: "test",
        label: "Remove"
      })

      {_module, _config} =
        start_server!([
          # Updated metadata
          %{key: "keep_me", type: "string", value: "default", category: "new", label: "New Label"},
          # New flag
          %{key: "add_me", type: "boolean", value: "true", category: "test", label: "New Flag"}
        ])

      # Kept with updated metadata, original value preserved
      kept = TestRepo.get_by(Entry, key: "keep_me")
      assert kept.label == "New Label"
      assert kept.category == "new"
      assert kept.value == "original"

      # Removed
      refute TestRepo.get_by(Entry, key: "remove_me")

      # Added
      added = TestRepo.get_by(Entry, key: "add_me")
      assert added.value == "true"
      assert added.type == "boolean"
    end

    test "works with Flag structs" do
      alias PhoenixFlags.Flag

      {_module, _config} =
        start_server!([
          Flag.new!(
            key: "struct_flag",
            type: :boolean,
            default: "true",
            category: "integrations",
            label: "Struct Flag",
            description: "Created from a struct"
          )
        ])

      entry = TestRepo.get_by(Entry, key: "struct_flag")
      assert entry.value == "true"
      assert entry.type == "boolean"
      assert entry.category == "integrations"
      assert entry.label == "Struct Flag"
      assert entry.description == "Created from a struct"
    end

    test "no-op when flags match DB exactly" do
      TestRepo.insert!(%Entry{
        key: "perfect",
        value: "true",
        type: "boolean",
        category: "test",
        label: "Perfect"
      })

      {_module, _config} =
        start_server!([
          %{key: "perfect", type: "boolean", value: "false", category: "test", label: "Perfect"}
        ])

      entry = TestRepo.get_by(Entry, key: "perfect")
      # Everything unchanged
      assert entry.value == "true"
      assert entry.type == "boolean"
      assert entry.label == "Perfect"
    end
  end
end
