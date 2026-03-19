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
      for key <- [:cache, :entries, :config] do
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
      # Verify entries are in persistent_term
      entries = :persistent_term.get({PhoenixFlags, CachedConfig, :entries})
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
    test "erases config key but preserves cache for graceful degradation" do
      # All keys exist while running
      assert :persistent_term.get({PhoenixFlags, CachedConfig, :cache}) |> is_map()
      assert :persistent_term.get({PhoenixFlags, CachedConfig, :entries}) |> is_list()
      assert :persistent_term.get({PhoenixFlags, CachedConfig, :config}) |> is_struct()

      stop_supervised!(PhoenixFlags.Server)

      # Config key erased — server is no longer "running"
      assert_raise ArgumentError, fn ->
        :persistent_term.get({PhoenixFlags, CachedConfig, :config})
      end

      # Cache and entries preserved — get/3 can serve stale values during restart
      assert :persistent_term.get({PhoenixFlags, CachedConfig, :cache}) |> is_map()
      assert :persistent_term.get({PhoenixFlags, CachedConfig, :entries}) |> is_list()
    end
  end

  describe "get/3 resilience" do
    test "returns default when server is not running" do
      stop_supervised!(PhoenixFlags.Server)

      assert CachedConfig.get("cached_bool", :fallback) == :fallback
      assert CachedConfig.get("nonexistent") == nil
    end
  end

  describe "all_grouped/0 resilience" do
    test "returns empty list when server is not running" do
      stop_supervised!(PhoenixFlags.Server)

      assert CachedConfig.all_grouped() == []
    end
  end
end
