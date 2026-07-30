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
          %{
            key: "existing_flag",
            type: "boolean",
            value: "false",
            category: "test",
            label: "Existing"
          }
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
          %{
            key: "recategorized",
            type: "integer",
            value: "0",
            category: "new_category",
            label: "Flag"
          }
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
          %{
            key: "int_to_bool",
            type: "boolean",
            value: "false",
            category: "test",
            label: "Int to Bool"
          }
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
          %{
            key: "str_to_pct",
            type: "percentage",
            value: "50",
            category: "test",
            label: "Str to Pct"
          }
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
          %{
            key: "keep_me",
            type: "string",
            value: "default",
            category: "new",
            label: "New Label"
          },
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

  describe "concurrent seed" do
    test "two servers seeding the same flags simultaneously do not error or lose data" do
      flags = [
        %{key: "race_a", type: "boolean", value: "true", category: "test", label: "Race A"},
        %{key: "race_b", type: "integer", value: "42", category: "test", label: "Race B"},
        %{key: "race_c", type: "string", value: "hello", category: "test", label: "Race C"}
      ]

      # Both configs share the same flags module (simulating two nodes with same code)
      module_name = :"PhoenixFlags.SeedTest.SharedFlags#{System.unique_integer([:positive])}"

      Module.create(
        module_name,
        quote do
          def flags, do: unquote(Macro.escape(flags))
        end,
        Macro.Env.location(__ENV__)
      )

      config1 = %Config{
        otp_app: :phoenix_flags,
        repo: TestRepo,
        name: :"#{module_name}.Node1",
        cache_enabled: false
      }

      config2 = %Config{
        otp_app: :phoenix_flags,
        repo: TestRepo,
        name: :"#{module_name}.Node2",
        cache_enabled: false
      }

      # Patch both names to use the shared flags module
      Module.create(
        config1.name,
        quote(do: defdelegate(flags(), to: unquote(module_name))),
        Macro.Env.location(__ENV__)
      )

      Module.create(
        config2.name,
        quote(do: defdelegate(flags(), to: unquote(module_name))),
        Macro.Env.location(__ENV__)
      )

      # Start both servers concurrently against the same database.
      # Unlink so the server survives after the task exits.
      start_fn = fn config ->
        {:ok, pid} = Server.start_link(config)
        Process.unlink(pid)
        pid
      end

      task1 = Task.async(fn -> start_fn.(config1) end)
      task2 = Task.async(fn -> start_fn.(config2) end)

      pid1 = Task.await(task1)
      pid2 = Task.await(task2)

      # Both started without error — verify all flags exist exactly once
      assert TestRepo.get_by(Entry, key: "race_a")
      assert TestRepo.get_by(Entry, key: "race_b")
      assert TestRepo.get_by(Entry, key: "race_c")

      import Ecto.Query
      assert TestRepo.aggregate(where(Entry, [e], e.key == "race_a"), :count) == 1
      assert TestRepo.aggregate(where(Entry, [e], e.key == "race_b"), :count) == 1
      assert TestRepo.aggregate(where(Entry, [e], e.key == "race_c"), :count) == 1

      GenServer.stop(pid1)
      GenServer.stop(pid2)
    end
  end

  describe "repo sharing guard" do
    test "a second config module with different flags on the same repo refuses to start" do
      make_module = fn flags ->
        module_name = :"PhoenixFlags.SeedTest.Guard#{System.unique_integer([:positive])}"

        Module.create(
          module_name,
          quote do
            def flags, do: unquote(Macro.escape(flags))
          end,
          Macro.Env.location(__ENV__)
        )

        module_name
      end

      module_a =
        make_module.([
          %{key: "guard_a", type: "boolean", value: "true", category: "test", label: "A"}
        ])

      module_b =
        make_module.([
          %{key: "guard_b", type: "boolean", value: "true", category: "test", label: "B"}
        ])

      config_a = %Config{
        otp_app: :phoenix_flags,
        repo: TestRepo,
        name: module_a,
        cache_enabled: false
      }

      config_b = %Config{
        otp_app: :phoenix_flags,
        repo: TestRepo,
        name: module_b,
        cache_enabled: false
      }

      on_exit(fn -> :persistent_term.erase({PhoenixFlags, :repo_claim, TestRepo}) end)

      Process.flag(:trap_exit, true)

      {:ok, pid_a} = Server.start_link(config_a)

      assert {:error, {%PhoenixFlags.Error{message: message}, _stacktrace}} =
               Server.start_link(config_b)

      assert message =~ "both use repo"
      assert message =~ "one config module per repo"

      # module_a's flags were not touched by the refused instance
      assert TestRepo.get_by(Entry, key: "guard_a")
      refute TestRepo.get_by(Entry, key: "guard_b")

      GenServer.stop(pid_a)
    end
  end

  describe "server init without DB" do
    test "crashes cleanly and logs warning when database is unavailable" do
      import ExUnit.CaptureLog

      flags = [
        %{key: "no_db", type: "boolean", value: "true", category: "test", label: "No DB"}
      ]

      module_name = :"PhoenixFlags.SeedTest.NoDB#{System.unique_integer([:positive])}"

      Module.create(
        module_name,
        quote do
          def flags, do: unquote(Macro.escape(flags))
        end,
        Macro.Env.location(__ENV__)
      )

      config = %Config{
        otp_app: :phoenix_flags,
        repo: PhoenixFlags.FakeRepo,
        name: module_name,
        cache_enabled: false
      }

      # Server should crash during init — not hang or silently degrade
      Process.flag(:trap_exit, true)

      log =
        capture_log(fn ->
          assert {:error, _reason} = Server.start_link(config)
        end)

      assert log =~ "failed to sync flags"
    end
  end
end
