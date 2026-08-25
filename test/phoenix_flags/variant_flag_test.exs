defmodule PhoenixFlags.VariantFlagTest do
  use PhoenixFlags.DataCase

  alias PhoenixFlags.Config
  alias PhoenixFlags.Entry
  alias PhoenixFlags.Server

  defmodule VConfig do
    use PhoenixFlags, otp_app: :phoenix_flags, repo: PhoenixFlags.TestRepo

    flag("checkout_flow",
      type: :variant,
      category: "experiments",
      label: "Checkout flow",
      variants: [{"Control", "control", 90}, {"New flow", "new_flow", 10}]
    )

    flag("plain", type: :boolean, default: "true", category: "other", label: "Plain")
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

  defp start_uncached! do
    config = %Config{
      otp_app: :phoenix_flags,
      repo: TestRepo,
      name: VConfig,
      cache_enabled: false
    }

    :persistent_term.put({PhoenixFlags, VConfig, :config}, config)
    cleanup_persistent_term(VConfig)
    config
  end

  defp start_cached! do
    start_supervised!(
      {Server,
       %Config{otp_app: :phoenix_flags, repo: TestRepo, name: VConfig, cache_enabled: true}}
    )

    cleanup_persistent_term(VConfig)
  end

  defp insert_split!(value) do
    TestRepo.insert!(%Entry{
      key: "checkout_flow",
      value: value,
      type: "variant",
      category: "experiments",
      label: "Checkout flow"
    })
  end

  describe "declaration" do
    test "variants/1 exposes the declared variants" do
      assert VConfig.variants("checkout_flow") == [
               {"Control", "control", 90},
               {"New flow", "new_flow", 10}
             ]
    end

    test "variants/1 returns [] for a non-variant flag and an unknown key" do
      assert VConfig.variants("plain") == []
      assert VConfig.variants("nope") == []
    end
  end

  describe "seeding" do
    test "writes the declared weights as the initial stored value" do
      start_cached!()

      assert TestRepo.get_by!(Entry, key: "checkout_flow").value == "control=90,new_flow=10"
      assert TestRepo.get_by!(Entry, key: "checkout_flow").type == "variant"
    end
  end

  describe "variant/3 (cached)" do
    setup do
      start_cached!()
      :ok
    end

    test "assigns deterministically" do
      first = for index <- 1..20, do: VConfig.variant("checkout_flow", "user-#{index}")
      again = for index <- 1..20, do: VConfig.variant("checkout_flow", "user-#{index}")

      assert first == again
      assert Enum.all?(first, &(&1 in ["control", "new_flow"]))
    end

    test "honours a runtime rollout change" do
      assert {:ok, _} =
               VConfig.update_entry("checkout_flow", %{"value" => "control=0,new_flow=100"})

      assert Enum.all?(1..20, &(VConfig.variant("checkout_flow", "u-#{&1}") == "new_flow"))
    end

    test "returns the default for an unknown key" do
      assert VConfig.variant("nope", "user-1") == nil
      assert VConfig.variant("nope", "user-1", default: "control") == "control"
    end

    test "returns the default for a non-variant flag" do
      assert VConfig.variant("plain", "user-1", default: :nope) == :nope
    end
  end

  describe "variant/3 (uncached)" do
    setup do
      start_uncached!()
      insert_split!("control=90,new_flow=10")
      :ok
    end

    test "reads the split from the database" do
      assert VConfig.variant("checkout_flow", "user-1") in ["control", "new_flow"]
    end

    test "agrees with the cached path for the same identity and split" do
      uncached = for index <- 1..20, do: VConfig.variant("checkout_flow", "user-#{index}")

      # Same split, same identities, so the cache must not change the answer.
      :persistent_term.put(
        {PhoenixFlags, VConfig, :cache},
        {%{
           "checkout_flow" => PhoenixFlags.Variant.parse("control=90,new_flow=10") |> elem(1)
         }, []}
      )

      :persistent_term.put(
        {PhoenixFlags, VConfig, :config},
        %Config{otp_app: :phoenix_flags, repo: TestRepo, name: VConfig, cache_enabled: true}
      )

      cached = for index <- 1..20, do: VConfig.variant("checkout_flow", "user-#{index}")

      assert uncached == cached
    end

    test "a stub forces a variant regardless of identity" do
      VConfig.Test.stub("checkout_flow", "new_flow")

      assert Enum.all?(1..20, &(VConfig.variant("checkout_flow", "u-#{&1}") == "new_flow"))
    end
  end

  describe "get/2 refuses a variant flag" do
    setup do
      start_cached!()
      :ok
    end

    test "raises and names variant/2" do
      assert_raise PhoenixFlags.Error, ~r/is a :variant flag and has no single value/, fn ->
        VConfig.get("checkout_flow")
      end

      assert_raise PhoenixFlags.Error, ~r/variant\("checkout_flow", identity\)/, fn ->
        VConfig.get("checkout_flow", "fallback")
      end
    end

    test "still works for other flags" do
      assert VConfig.get("plain") == true
    end
  end

  describe "update_entry/3 validation" do
    setup do
      start_uncached!()
      insert_split!("control=90,new_flow=10")
      :ok
    end

    test "accepts a valid split" do
      assert {:ok, entry} =
               VConfig.update_entry("checkout_flow", %{"value" => "control=20,new_flow=80"})

      assert entry.value == "control=20,new_flow=80"
    end

    test "rejects weights that do not total 100" do
      assert {:error, changeset} =
               VConfig.update_entry("checkout_flow", %{"value" => "control=20,new_flow=30"})

      assert "weights must total 100, got 50" in errors_on(changeset).value
    end

    test "rejects an undeclared variant name" do
      assert {:error, changeset} =
               VConfig.update_entry("checkout_flow", %{"value" => "control=50,bogus=50"})

      assert Enum.any?(errors_on(changeset).value, &(&1 =~ "unknown variant(s) bogus"))
    end

    test "leaves the stored split untouched when rejected" do
      assert {:error, _} =
               VConfig.update_entry("checkout_flow", %{"value" => "control=1,new_flow=2"})

      assert TestRepo.get_by!(Entry, key: "checkout_flow").value == "control=90,new_flow=10"
    end
  end

  describe "telemetry" do
    setup do
      start_cached!()
      :ok
    end

    test "emits an exposure event only when asked" do
      parent = self()
      handler = "variant-test-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:phoenix_flags, :variant, :assigned],
        fn _event, _measurements, metadata, _config -> send(parent, {:assigned, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assigned = VConfig.variant("checkout_flow", "user-1", telemetry: true)

      assert_receive {:assigned, metadata}
      assert metadata.flag == "checkout_flow"
      assert metadata.identity == "user-1"
      assert metadata.variant == assigned
      assert metadata.instance == VConfig

      VConfig.variant("checkout_flow", "user-2")
      refute_receive {:assigned, _}, 50
    end
  end

  describe "cast" do
    test "an unparseable stored split warns and yields nil rather than a bad variant" do
      import ExUnit.CaptureLog

      log = capture_log(fn -> assert Entry.cast_value("control=50,new=30", "variant") == nil end)

      assert log =~ "failed to cast"
      assert log =~ "weights must total 100"
    end
  end
end
