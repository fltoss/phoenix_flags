defmodule PhoenixFlags.TargetingTest do
  use PhoenixFlags.DataCase

  import ExUnit.CaptureLog
  import Ecto.Query, only: [from: 2]

  alias PhoenixFlags.Config
  alias PhoenixFlags.Entry
  alias PhoenixFlags.Server

  defmodule Encryptor do
    def encrypt(plaintext), do: Base.encode64(plaintext)
    def decrypt(ciphertext), do: Base.decode64!(ciphertext)
  end

  defmodule TConfig do
    use PhoenixFlags,
      otp_app: :phoenix_flags,
      repo: PhoenixFlags.TestRepo,
      encryptor: PhoenixFlags.TargetingTest.Encryptor

    flag("enable_benefits", type: :boolean, default: "false", category: "a", label: "Benefits")
    flag("rate_limit", type: :integer, default: "100", category: "a", label: "Rate limit")
    flag("greeting", type: :string, default: "hi", category: "a", label: "Greeting")

    flag("checkout_flow",
      type: :variant,
      category: "e",
      label: "Checkout",
      variants: [{"Control", "control", 100}, {"New", "new_flow", 0}]
    )

    flag("api_key", type: :secret, category: "s", label: "API Key")
  end

  defp cleanup(module) do
    on_exit(fn ->
      for key <- [:cache, :config, :order, :targets] do
        try do
          :persistent_term.erase({PhoenixFlags, module, key})
        rescue
          ArgumentError -> :ok
        end
      end
    end)
  end

  defp start_cached! do
    start_supervised!(
      {Server,
       %Config{
         otp_app: :phoenix_flags,
         repo: TestRepo,
         name: TConfig,
         cache_enabled: true,
         encryptor: Encryptor
       }}
    )

    cleanup(TConfig)
    on_exit(fn -> PhoenixFlags.clear_context() end)
    :ok
  end

  defp start_uncached! do
    config = %Config{
      otp_app: :phoenix_flags,
      repo: TestRepo,
      name: TConfig,
      cache_enabled: false,
      encryptor: Encryptor
    }

    :persistent_term.put({PhoenixFlags, TConfig, :config}, config)
    cleanup(TConfig)
    on_exit(fn -> PhoenixFlags.clear_context() end)
    config
  end

  defp rule!(key, attribute, values, value) do
    {:ok, target} =
      TConfig.put_target(key,
        conditions: [[attribute: attribute, operator: :in, values: values]],
        value: value
      )

    target
  end

  describe "precedence" do
    setup do: start_cached!()

    test "a matching rule beats the stored value" do
      rule!("enable_benefits", :company_id, [123], "true")

      assert TConfig.get("enable_benefits", false) == false
      PhoenixFlags.put_context(company_id: 123)
      assert TConfig.get("enable_benefits", false) == true
    end

    test "a matching rule beats a variant split" do
      # The split is 100/0, so only a rule can ever produce "new_flow".
      rule!("checkout_flow", :user_id, [7], "new_flow")

      assert TConfig.variant("checkout_flow", "u-1") == "control"
      PhoenixFlags.put_context(user_id: 7)
      assert TConfig.variant("checkout_flow", "u-1") == "new_flow"
    end

    test "the first matching rule wins, by position" do
      rule!("greeting", :tier, ["gold"], "first")
      rule!("greeting", :tier, ["gold"], "second")

      PhoenixFlags.put_context(tier: "gold")
      assert TConfig.get("greeting") == "first"
    end

    test "a non-matching rule falls through to the stored value" do
      rule!("enable_benefits", :company_id, [123], "true")

      PhoenixFlags.put_context(company_id: 999)
      assert TConfig.get("enable_benefits", false) == false
    end

    test "a rule on another flag does not leak" do
      rule!("enable_benefits", :company_id, [123], "true")

      PhoenixFlags.put_context(company_id: 123)
      assert TConfig.get("greeting") == "hi"
    end
  end

  describe "precedence (uncached)" do
    setup do
      start_uncached!()

      TestRepo.insert!(%Entry{
        key: "enable_benefits",
        value: "false",
        type: "boolean",
        category: "a",
        label: "Benefits"
      })

      :ok
    end

    test "a rule beats the database read" do
      rule!("enable_benefits", :company_id, [123], "true")

      PhoenixFlags.put_context(company_id: 123)
      assert TConfig.get("enable_benefits", false) == true
    end

    test "a test stub still beats a rule" do
      # Stubs are the test escape hatch and must stay at the top of the chain.
      rule!("enable_benefits", :company_id, [123], "true")
      TConfig.Test.stub("enable_benefits", :stubbed)

      PhoenixFlags.put_context(company_id: 123)
      assert TConfig.get("enable_benefits", false) == :stubbed
    end
  end

  describe "value casting" do
    setup do: start_cached!()

    test "a rule value is cast to the flag's type, not returned as a string" do
      rule!("enable_benefits", :c, [1], "true")
      rule!("rate_limit", :c, [1], "5000")
      rule!("greeting", :c, [1], "hello")

      PhoenixFlags.put_context(c: 1)

      assert TConfig.get("enable_benefits", false) === true
      assert TConfig.get("rate_limit") === 5000
      assert TConfig.get("greeting") === "hello"
    end

    test "a :variant rule returns the variant name as-is" do
      rule!("checkout_flow", :c, [1], "new_flow")

      PhoenixFlags.put_context(c: 1)
      assert TConfig.variant("checkout_flow", "anyone") == "new_flow"
    end
  end

  describe "context resolution" do
    setup do
      start_cached!()
      rule!("enable_benefits", :company_id, [123], "true")
      :ok
    end

    test "an explicit context overrides the process context" do
      PhoenixFlags.put_context(company_id: 999)

      assert TConfig.get("enable_benefits", false, context: %{company_id: 123}) == true
      assert TConfig.get("enable_benefits", false) == false
    end

    test "an explicit keyword context works too" do
      assert TConfig.get("enable_benefits", false, context: [company_id: 123]) == true
    end

    test "no context at all skips targeting" do
      assert PhoenixFlags.context() == %{}
      assert TConfig.get("enable_benefits", false) == false
    end

    test "clearing the context disables targeting" do
      PhoenixFlags.put_context(company_id: 123)
      assert TConfig.get("enable_benefits", false) == true

      PhoenixFlags.clear_context()
      assert TConfig.get("enable_benefits", false) == false
    end

    test "merge_context/1 adds to what is already there" do
      PhoenixFlags.put_context(user_id: 1)
      PhoenixFlags.merge_context(company_id: 123)

      assert PhoenixFlags.context() == %{user_id: 1, company_id: 123}
      assert TConfig.get("enable_benefits", false) == true
    end

    test "the context is not inherited by a spawned process" do
      # Documented limitation: the process dictionary does not cross process
      # boundaries, so a Task sees no context unless it is passed explicitly.
      PhoenixFlags.put_context(company_id: 123)
      assert TConfig.get("enable_benefits", false) == true

      assert Task.await(Task.async(fn -> TConfig.get("enable_benefits", false) end)) == false

      context = PhoenixFlags.context()
      task = Task.async(fn -> TConfig.get("enable_benefits", false, context: context) end)
      assert Task.await(task) == true
    end

    test "a malformed context does not raise" do
      for context <- [nil, "x", 42, %{}, %{nil => nil}, %{a: self()}] do
        assert TConfig.get("enable_benefits", :fallback, context: context) in [false, :fallback]
      end
    end

    test "a malformed opts does not raise" do
      assert TConfig.get("enable_benefits", false, %{context: %{company_id: 123}}) == false
    end
  end

  describe "put_target/2 validation" do
    setup do: start_cached!()

    test "rejects a value that is wrong for the flag's type" do
      assert {:error, changeset} =
               TConfig.put_target("enable_benefits",
                 conditions: [[attribute: :c, operator: :in, values: [1]]],
                 value: "not-a-boolean"
               )

      assert "must be true or false" in errors_on(changeset).value
    end

    test "reports a type error exactly once" do
      {:error, changeset} =
        TConfig.put_target("rate_limit",
          conditions: [[attribute: :c, operator: :in, values: [1]]],
          value: "abc"
        )

      assert length(errors_on(changeset).value) == 1
    end

    test "rejects a :variant value that is not a declared variant" do
      assert {:error, changeset} =
               TConfig.put_target("checkout_flow",
                 conditions: [[attribute: :c, operator: :in, values: [1]]],
                 value: "bogus"
               )

      assert "must name one of the declared variants: control, new_flow" in errors_on(changeset).value
    end

    test "accepts a declared variant name rather than a weights string" do
      assert {:ok, _} =
               TConfig.put_target("checkout_flow",
                 conditions: [[attribute: :c, operator: :in, values: [1]]],
                 value: "control"
               )
    end

    test "refuses to target a :secret flag" do
      assert {:error, changeset} =
               TConfig.put_target("api_key",
                 conditions: [[attribute: :c, operator: :in, values: [1]]],
                 value: "sekrit"
               )

      assert Enum.any?(errors_on(changeset).value, &(&1 =~ "cannot be targeted"))
    end

    test "requires at least one condition" do
      assert {:error, changeset} =
               TConfig.put_target("greeting", conditions: [], value: "x")

      refute changeset.valid?
    end

    test "rejects an empty values list, which would match everyone" do
      assert {:error, changeset} =
               TConfig.put_target("greeting",
                 conditions: [[attribute: :c, operator: :not_in, values: []]],
                 value: "x"
               )

      refute changeset.valid?
    end

    test "returns :not_found for an unknown flag" do
      assert TConfig.put_target("nope",
               conditions: [[attribute: :c, operator: :in, values: [1]]],
               value: "x"
             ) == {:error, :not_found}
    end

    test "assigns increasing positions" do
      assert rule!("greeting", :c, [1], "a").position == 0
      assert rule!("greeting", :c, [2], "b").position == 1
    end
  end

  describe "targets/1 and delete_target/1" do
    setup do: start_cached!()

    test "lists rules in evaluation order with their conditions" do
      rule!("greeting", :c, [1], "a")
      rule!("greeting", :c, [2], "b")

      assert [first, second] = TConfig.targets("greeting")
      assert first.value == "a"
      assert second.value == "b"
      assert [%{attribute: "c", operator: "in", values: ["1"]}] = first.conditions
    end

    test "returns [] for a flag with no rules" do
      assert TConfig.targets("greeting") == []
    end

    test "deleting a rule stops it applying, and takes its conditions with it" do
      target = rule!("enable_benefits", :company_id, [123], "true")
      PhoenixFlags.put_context(company_id: 123)
      assert TConfig.get("enable_benefits", false) == true

      assert {:ok, _} = TConfig.delete_target(target.id)

      assert TConfig.get("enable_benefits", false) == false
      assert TConfig.targets("enable_benefits") == []
      assert TestRepo.all(PhoenixFlags.Target.Condition) == []
    end

    test "deleting an unknown id is an error, not a crash" do
      assert TConfig.delete_target(Ecto.UUID.generate()) == {:error, :not_found}
      capture_log(fn -> assert TConfig.delete_target("not-a-uuid") == {:error, :not_found} end)
    end
  end

  describe "cluster replication" do
    test "a rule written by one instance reaches another after :reload" do
      start_cached!()
      rule!("enable_benefits", :company_id, [123], "true")

      # A peer's cache is refreshed by the :reload message notify_peers/1 sends.
      # Erase this node's targets to stand in for a peer that has never loaded
      # them, then drive the reload the same way a peer would.
      :persistent_term.put({PhoenixFlags, TConfig, :targets}, %{})
      PhoenixFlags.put_context(company_id: 123)
      assert TConfig.get("enable_benefits", false) == false

      send(TConfig, :reload)
      # Round-trip a call so the cast-like send is processed before asserting.
      _ = :sys.get_state(TConfig)

      assert TConfig.get("enable_benefits", false) == true
    end
  end

  describe "seeding interaction" do
    setup do: start_cached!()

    test "a rule for a flag that no longer exists is simply not loaded" do
      rule!("greeting", :c, [1], "x")
      TestRepo.delete_all(from(e in Entry, where: e.key == "greeting"))

      send(TConfig, :reload)
      _ = :sys.get_state(TConfig)

      PhoenixFlags.put_context(c: 1)
      assert TConfig.get("greeting", :gone) == :gone
    end
  end
end
