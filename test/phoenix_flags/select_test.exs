defmodule PhoenixFlags.SelectTest do
  use PhoenixFlags.DataCase

  alias PhoenixFlags.Config
  alias PhoenixFlags.Entry
  alias PhoenixFlags.Server

  @options [{"Basic", "basic"}, {"Pro", "pro"}, {"Enterprise", "enterprise"}]

  defmodule SelectConfig do
    use PhoenixFlags,
      otp_app: :phoenix_flags,
      repo: PhoenixFlags.TestRepo

    flag("feature_tier",
      type: :select,
      default: "basic",
      category: "product",
      label: "Feature Tier",
      options: [{"Basic", "basic"}, {"Pro", "pro"}, {"Enterprise", "enterprise"}]
    )
  end

  defp cleanup_persistent_term(module) do
    on_exit(fn ->
      for key <- [:cache, :config, :order] do
        try do
          :persistent_term.erase({PhoenixFlags, module, key})
        rescue
          ArgumentError -> :ok
        end
      end
    end)
  end

  defp start_uncached!(module) do
    config = %Config{
      otp_app: :phoenix_flags,
      repo: TestRepo,
      name: module,
      cache_enabled: false
    }

    :persistent_term.put({PhoenixFlags, module, :config}, config)
    cleanup_persistent_term(module)
    config
  end

  defp insert_tier!(value) do
    TestRepo.insert!(%Entry{
      key: "feature_tier",
      value: value,
      type: "select",
      category: "product",
      label: "Feature Tier"
    })
  end

  describe "declared options" do
    test "are exposed by the generated select_options/1" do
      assert SelectConfig.select_options("feature_tier") == @options
    end

    test "are empty for a key that is not a select flag" do
      assert SelectConfig.select_options("nope") == []
    end
  end

  describe "update_entry/3 in the caller's process (cache_enabled: false)" do
    setup do
      start_uncached!(SelectConfig)
      insert_tier!("basic")
      :ok
    end

    test "accepts a declared option" do
      assert {:ok, entry} = SelectConfig.update_entry("feature_tier", %{"value" => "pro"})
      assert entry.value == "pro"
      assert SelectConfig.get("feature_tier") == "pro"
    end

    test "rejects a value that is not one of the declared options" do
      assert {:error, changeset} =
               SelectConfig.update_entry("feature_tier", %{"value" => "platinum"})

      assert "must be one of: basic, pro, enterprise" in errors_on(changeset).value
    end

    test "leaves the stored value untouched when rejected" do
      assert {:error, _changeset} =
               SelectConfig.update_entry("feature_tier", %{"value" => "platinum"})

      assert TestRepo.get_by!(Entry, key: "feature_tier").value == "basic"
      assert SelectConfig.get("feature_tier") == "basic"
    end

    test "rejects a near-miss on casing" do
      assert {:error, _changeset} = SelectConfig.update_entry("feature_tier", %{"value" => "Pro"})
    end

    test "accepts atom-keyed attrs for a declared option" do
      assert {:ok, entry} = SelectConfig.update_entry("feature_tier", %{value: "enterprise"})
      assert entry.value == "enterprise"
    end

    test "rejects atom-keyed attrs for an undeclared value" do
      assert {:error, _changeset} =
               SelectConfig.update_entry("feature_tier", %{value: "platinum"})
    end
  end

  describe "update_entry/3 through the GenServer (cache_enabled: true)" do
    setup do
      insert_tier!("basic")

      config = %Config{
        otp_app: :phoenix_flags,
        repo: TestRepo,
        name: SelectConfig,
        cache_enabled: true
      }

      start_supervised!({Server, config})
      cleanup_persistent_term(SelectConfig)
      :ok
    end

    test "accepts a declared option and caches it" do
      assert {:ok, _entry} = SelectConfig.update_entry("feature_tier", %{"value" => "pro"})
      assert SelectConfig.get("feature_tier") == "pro"
    end

    test "rejects an undeclared value and leaves the cache alone" do
      assert {:error, changeset} =
               SelectConfig.update_entry("feature_tier", %{"value" => "platinum"})

      assert "must be one of: basic, pro, enterprise" in errors_on(changeset).value
      assert SelectConfig.get("feature_tier") == "basic"
    end
  end

  describe "other types are unaffected" do
    setup do
      start_uncached!(SelectConfig)
      :ok
    end

    test "a string flag still accepts arbitrary values" do
      TestRepo.insert!(%Entry{
        key: "greeting",
        value: "hello",
        type: "string",
        category: "product",
        label: "Greeting"
      })

      assert {:ok, entry} = SelectConfig.update_entry("greeting", %{"value" => "anything at all"})
      assert entry.value == "anything at all"
    end

    test "a select entry with no matching declaration is not membership-checked" do
      # select_options/1 returns [] for an undeclared key, so there is no
      # allowed set to check against — the write must not be blocked.
      TestRepo.insert!(%Entry{
        key: "legacy_choice",
        value: "a",
        type: "select",
        category: "product",
        label: "Legacy Choice"
      })

      assert {:ok, entry} = SelectConfig.update_entry("legacy_choice", %{"value" => "z"})
      assert entry.value == "z"
    end
  end
end
