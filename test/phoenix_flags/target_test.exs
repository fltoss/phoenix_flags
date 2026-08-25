defmodule PhoenixFlags.TargetTest do
  use ExUnit.Case, async: true

  alias PhoenixFlags.Target
  alias PhoenixFlags.Target.Condition

  defp condition(attribute, operator, values) do
    %Condition{attribute: attribute, operator: operator, values: values}
  end

  defp target(conditions, value \\ "true", position \\ 0) do
    %Target{key: "f", value: value, position: position, conditions: conditions}
  end

  describe "matches?/2 — operators" do
    test ":in matches any listed value" do
      rule = target([condition("company_id", "in", ["123", "456"])])

      assert Target.matches?(rule, %{company_id: "123"})
      assert Target.matches?(rule, %{company_id: "456"})
      refute Target.matches?(rule, %{company_id: "789"})
    end

    test ":not_in matches anything listed values do not cover" do
      rule = target([condition("company_id", "not_in", ["123"])])

      assert Target.matches?(rule, %{company_id: "999"})
      refute Target.matches?(rule, %{company_id: "123"})
    end

    test ":eq matches the first value only" do
      rule = target([condition("plan", "eq", ["enterprise", "ignored"])])

      assert Target.matches?(rule, %{plan: "enterprise"})
      refute Target.matches?(rule, %{plan: "ignored"})
    end

    test ":starts_with matches any prefix" do
      rule = target([condition("email", "starts_with", ["qa@", "test@"])])

      assert Target.matches?(rule, %{email: "qa@example.com"})
      assert Target.matches?(rule, %{email: "test@example.com"})
      refute Target.matches?(rule, %{email: "real@example.com"})
    end

    test "an unknown operator never matches" do
      refute Target.matches?(target([condition("a", "regex", ["x"])]), %{a: "x"})
    end
  end

  describe "matches?/2 — coercion" do
    test "an integer context value matches a string rule value" do
      assert Target.matches?(target([condition("company_id", "in", ["123"])]), %{company_id: 123})
    end

    test "an atom attribute key matches a string attribute" do
      rule = target([condition("company_id", "in", ["123"])])

      assert Target.matches?(rule, %{company_id: 123})
      assert Target.matches?(rule, %{"company_id" => 123})
    end

    test "an atom context value is stringified" do
      assert Target.matches?(target([condition("plan", "eq", ["pro"])]), %{plan: :pro})
    end

    test "a float context value is stringified as Elixir would" do
      # Documented behaviour: to_string(1.5) is "1.5", so a rule must say "1.5".
      assert Target.matches?(target([condition("v", "eq", ["1.5"])]), %{v: 1.5})
      refute Target.matches?(target([condition("v", "eq", ["1.50"])]), %{v: 1.5})
    end

    test "a value with no String.Chars implementation never matches, and does not raise" do
      rule = target([condition("a", "in", ["x"])])

      refute Target.matches?(rule, %{a: %{}})
      refute Target.matches?(rule, %{a: {1, 2}})
      refute Target.matches?(rule, %{a: self()})
    end
  end

  describe "matches?/2 — absence" do
    test "a missing attribute does not match" do
      refute Target.matches?(target([condition("company_id", "in", ["123"])]), %{user_id: 1})
      refute Target.matches?(target([condition("company_id", "in", ["123"])]), %{})
    end

    test "a missing attribute does not match :not_in either" do
      # "everyone except these" must not sweep in callers we know nothing about.
      refute Target.matches?(target([condition("company_id", "not_in", ["123"])]), %{})
    end

    test "a rule with no conditions never matches" do
      # An empty condition list would otherwise force its value on everyone.
      refute Target.matches?(target([]), %{company_id: 123})
      refute Target.matches?(target([]), %{})
    end
  end

  describe "matches?/2 — multiple conditions are ANDed" do
    setup do
      %{
        rule: target([condition("plan", "eq", ["enterprise"]), condition("region", "in", ["eu"])])
      }
    end

    test "all match", %{rule: rule} do
      assert Target.matches?(rule, %{plan: "enterprise", region: "eu"})
    end

    test "one fails", %{rule: rule} do
      refute Target.matches?(rule, %{plan: "enterprise", region: "us"})
      refute Target.matches?(rule, %{plan: "starter", region: "eu"})
    end

    test "one is absent", %{rule: rule} do
      refute Target.matches?(rule, %{plan: "enterprise"})
    end
  end

  describe "resolve/2" do
    test "returns the first matching rule's value, in list order" do
      rules = [
        target([condition("c", "in", ["1"])], "first"),
        target([condition("c", "in", ["1"])], "second")
      ]

      assert Target.resolve(rules, %{c: 1}) == {:ok, "first"}
    end

    test "skips rules that do not match" do
      rules = [
        target([condition("c", "in", ["9"])], "no"),
        target([condition("c", "in", ["1"])], "yes")
      ]

      assert Target.resolve(rules, %{c: 1}) == {:ok, "yes"}
    end

    test "returns :none when nothing matches" do
      assert Target.resolve([target([condition("c", "in", ["9"])])], %{c: 1}) == :none
    end

    test "returns :none for an empty rule list" do
      assert Target.resolve([], %{c: 1}) == :none
    end
  end

  describe "resolve/2 and matches?/2 never raise" do
    @garbage_contexts [
      nil,
      "string",
      42,
      [],
      [a: 1],
      %{},
      %{nil => nil},
      %{%{} => "v"},
      %{{1, 2} => "v"},
      %{a: self()},
      %{a: nil},
      %{a: [1, 2]},
      %{"" => ""}
    ]

    test "with a garbage context" do
      rules = [target([condition("a", "in", ["1"])])]

      for context <- @garbage_contexts do
        assert Target.resolve(rules, context) in [:none, {:ok, "true"}],
               "unexpected result for #{inspect(context)}"
      end
    end

    test "with a garbage rule" do
      contexts = [%{a: "1"}, %{}]

      malformed = [
        %Target{},
        %Target{conditions: nil},
        %Target{conditions: []},
        %Target{conditions: [%Condition{}]},
        %Target{conditions: [%Condition{attribute: nil, operator: "in", values: ["1"]}]},
        %Target{conditions: [%Condition{attribute: "a", operator: nil, values: ["1"]}]},
        %Target{conditions: [%Condition{attribute: "a", operator: "in", values: nil}]},
        %Target{conditions: [condition("a", "in", ["1"]), %Condition{}]},
        %{not: "a target"},
        nil
      ]

      for rule <- malformed, context <- contexts do
        assert is_boolean(Target.matches?(rule, context)),
               "matches? did not return a boolean for #{inspect(rule)}"

        assert Target.resolve([rule], context) in [:none, {:ok, nil}, {:ok, "true"}]
      end
    end
  end

  describe "Condition.changeset/2" do
    defp changeset(attrs), do: Condition.changeset(%Condition{}, attrs)

    test "normalises atom attributes, operators and values to strings" do
      cs = changeset(%{attribute: :company_id, operator: :in, values: [123, :pro, 1.5, "x"]})

      assert cs.valid?
      assert cs.changes.attribute == "company_id"
      assert cs.changes.operator == "in"
      assert cs.changes.values == ["123", "pro", "1.5", "x"]
    end

    test "requires an attribute and an operator" do
      refute changeset(%{values: ["1"]}).valid?
      refute changeset(%{attribute: "a", values: ["1"]}).valid?
    end

    test "rejects a blank attribute" do
      refute changeset(%{attribute: "   ", operator: "in", values: ["1"]}).valid?
    end

    test "rejects an unknown operator, listing the valid ones" do
      cs = changeset(%{attribute: "a", operator: "regex", values: ["1"]})

      refute cs.valid?
      assert {"must be one of: in, not_in, eq, starts_with", _} = cs.errors[:operator]
    end

    test "requires at least one value" do
      refute changeset(%{attribute: "a", operator: "in", values: []}).valid?
    end
  end

  describe "Target.changeset/2" do
    test "requires a key, a value and at least one condition" do
      refute Target.changeset(%Target{}, %{}).valid?
      refute Target.changeset(%Target{}, %{key: "f", value: "true"}).valid?

      assert Target.changeset(%Target{}, %{
               key: "f",
               value: "true",
               conditions: [%{attribute: "a", operator: "in", values: ["1"]}]
             }).valid?
    end

    test "rejects a negative position" do
      refute Target.changeset(%Target{}, %{
               key: "f",
               value: "true",
               position: -1,
               conditions: [%{attribute: "a", operator: "in", values: ["1"]}]
             }).valid?
    end
  end
end
