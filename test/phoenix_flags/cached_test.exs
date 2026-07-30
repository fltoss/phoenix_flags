defmodule PhoenixFlags.CachedTest do
  use PhoenixFlags.DataCase

  alias PhoenixFlags.Entry

  defmodule CachedConfig do
    use PhoenixFlags,
      otp_app: :phoenix_flags,
      repo: PhoenixFlags.TestRepo

    flag("cached_bool",
      type: :boolean,
      default: "true",
      category: "alpha",
      label: "Cached Bool"
    )

    flag("cached_int",
      type: :integer,
      default: "10",
      category: "beta",
      label: "Cached Int"
    )

    flag("cached_str",
      type: :string,
      default: "hello",
      category: "alpha",
      label: "Cached Str"
    )
  end

  setup do
    config = %PhoenixFlags.Config{
      otp_app: :phoenix_flags,
      repo: TestRepo,
      name: CachedConfig,
      cache_enabled: true
    }

    pid = start_supervised!({PhoenixFlags.Server, config})

    on_exit(fn ->
      for key <- [:cache, :config, :order] do
        try do
          :persistent_term.erase({PhoenixFlags, CachedConfig, key})
        rescue
          ArgumentError -> :ok
        end
      end
    end)

    %{server: pid, config: config}
  end

  describe "get/3 with cache enabled" do
    test "reads seeded boolean from cache" do
      assert CachedConfig.get("cached_bool") == true
    end

    test "reads seeded integer from cache" do
      assert CachedConfig.get("cached_int") == 10
    end

    test "reads seeded string from cache" do
      assert CachedConfig.get("cached_str") == "hello"
    end

    test "returns default for missing key" do
      assert CachedConfig.get("nonexistent", :fallback) == :fallback
    end

    test "returns nil for missing key without default" do
      assert CachedConfig.get("nonexistent") == nil
    end

    test "reflects updated values after update_entry" do
      assert {:ok, _} = CachedConfig.update_entry("cached_bool", %{"value" => "false"})

      assert CachedConfig.get("cached_bool") == false
    end
  end

  describe "all_grouped/0 with cache enabled" do
    test "returns entries from cache grouped by category" do
      grouped = CachedConfig.all_grouped()

      assert [{"alpha", alpha_entries}, {"beta", beta_entries}] = grouped
      assert length(alpha_entries) == 2
      assert length(beta_entries) == 1
    end

    test "entries have correct struct fields" do
      [{"alpha", alpha_entries}, _] = CachedConfig.all_grouped()

      entry = Enum.find(alpha_entries, &(&1.key == "cached_bool"))

      assert %Entry{} = entry
      assert entry.value == "true"
      assert entry.type == "boolean"
      assert entry.category == "alpha"
      assert entry.label == "Cached Bool"
    end

    test "returns updated entries after update_entry" do
      assert {:ok, _} = CachedConfig.update_entry("cached_int", %{"value" => "99"})

      grouped = CachedConfig.all_grouped()
      [_, {"beta", [beta_entry]}] = grouped

      assert beta_entry.key == "cached_int"
      assert beta_entry.value == "99"
    end

    test "reads from persistent_term, not the database" do
      # Verify cache tuple is in persistent_term
      {values, entries} = :persistent_term.get({PhoenixFlags, CachedConfig, :cache})
      assert map_size(values) == 3
      assert length(entries) == 3

      # Delete all rows from the DB — cached all_grouped should still work
      TestRepo.delete_all(Entry)

      grouped = CachedConfig.all_grouped()
      assert [{"alpha", alpha}, {"beta", beta}] = grouped
      assert length(alpha) == 2
      assert length(beta) == 1
    end

    test "cache and entries stay in sync after update" do
      assert {:ok, _} = CachedConfig.update_entry("cached_bool", %{"value" => "false"})

      # get/3 reads from value cache
      assert CachedConfig.get("cached_bool") == false

      # all_grouped reads from entries cache
      grouped = CachedConfig.all_grouped()
      [{"alpha", alpha_entries}, _] = grouped
      entry = Enum.find(alpha_entries, &(&1.key == "cached_bool"))
      assert entry.value == "false"
    end
  end

  describe "terminate/2" do
    test "preserves cache, config, and order keys so reads degrade to stale values" do
      # Keys exist while running
      {values, entries} = :persistent_term.get({PhoenixFlags, CachedConfig, :cache})
      assert is_map(values)
      assert is_list(entries)
      assert is_struct(:persistent_term.get({PhoenixFlags, CachedConfig, :config}))

      stop_supervised!(PhoenixFlags.Server)

      # All keys preserved — get/3 keeps serving (stale) values during a
      # restart instead of falling back to call-site defaults.
      assert is_struct(:persistent_term.get({PhoenixFlags, CachedConfig, :config}))
      {values, entries} = :persistent_term.get({PhoenixFlags, CachedConfig, :cache})
      assert is_map(values)
      assert is_list(entries)
      assert is_map(:persistent_term.get({PhoenixFlags, CachedConfig, :order}))
    end
  end

  describe "restart recovery" do
    test "server restart repopulates cache with fresh data" do
      # Update a value
      assert {:ok, _} = CachedConfig.update_entry("cached_bool", %{"value" => "false"})
      assert CachedConfig.get("cached_bool") == false

      # Stop the server
      stop_supervised!(PhoenixFlags.Server)

      # Restart with same config
      config = %PhoenixFlags.Config{
        otp_app: :phoenix_flags,
        repo: TestRepo,
        name: CachedConfig,
        cache_enabled: true
      }

      start_supervised!({PhoenixFlags.Server, config})

      # Cache should be repopulated from DB — the updated value persists
      assert CachedConfig.get("cached_bool") == false
      assert CachedConfig.get("cached_int") == 10

      # all_grouped should also work
      grouped = CachedConfig.all_grouped()
      assert [{"alpha", _}, {"beta", _}] = grouped
    end
  end

  describe "periodic refresh" do
    test ":refresh reloads the cache from the database", %{server: server} do
      # Change the DB behind the server's back — simulates a write on another
      # node whose :reload notification this node missed.
      Entry
      |> TestRepo.get_by!(key: "cached_str")
      |> Ecto.Changeset.change(value: "changed-behind-back")
      |> TestRepo.update!()

      assert CachedConfig.get("cached_str") == "hello"

      send(server, :refresh)
      :sys.get_state(server)

      assert CachedConfig.get("cached_str") == "changed-behind-back"
    end
  end

  describe "get/3 resilience" do
    test "keeps serving cached values while the server is restarting" do
      assert {:ok, _} = CachedConfig.update_entry("cached_bool", %{"value" => "false"})

      stop_supervised!(PhoenixFlags.Server)

      # A flag defaulting to true at the call site must not silently flip
      # back during a restart — the stale cached value wins.
      assert CachedConfig.get("cached_bool", true) == false
      assert CachedConfig.get("cached_int") == 10
      assert CachedConfig.get("nonexistent", :fallback) == :fallback
    end

    test "returns default when the server never started" do
      stop_supervised!(PhoenixFlags.Server)

      for key <- [:cache, :config, :order] do
        :persistent_term.erase({PhoenixFlags, CachedConfig, key})
      end

      assert CachedConfig.get("cached_bool", :fallback) == :fallback
      assert CachedConfig.get("nonexistent") == nil
    end
  end

  describe "all_grouped/0 resilience" do
    test "keeps serving cached entries while the server is restarting" do
      stop_supervised!(PhoenixFlags.Server)

      grouped = CachedConfig.all_grouped()
      assert [{"alpha", alpha}, {"beta", beta}] = grouped
      assert length(alpha) == 2
      assert length(beta) == 1
    end

    test "returns empty list when the server never started" do
      stop_supervised!(PhoenixFlags.Server)

      for key <- [:cache, :config, :order] do
        :persistent_term.erase({PhoenixFlags, CachedConfig, key})
      end

      assert CachedConfig.all_grouped() == []
    end
  end
end
