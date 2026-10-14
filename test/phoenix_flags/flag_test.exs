defmodule PhoenixFlags.FlagTest do
  use ExUnit.Case

  alias PhoenixFlags.Flag

  describe "new!/1" do
    test "creates a valid boolean flag" do
      flag = Flag.new!(key: "test", type: :boolean, default: "true")

      assert flag.key == "test"
      assert flag.type == :boolean
      assert flag.default == "true"
      assert flag.category == "default"
      assert flag.label == nil
    end

    test "creates a valid integer flag" do
      flag = Flag.new!(key: "count", type: :integer, default: "42", label: "Count")

      assert flag.key == "count"
      assert flag.type == :integer
      assert flag.default == "42"
      assert flag.label == "Count"
    end

    test "creates a valid decimal flag" do
      flag = Flag.new!(key: "amount", type: :decimal, default: "3000.50")

      assert flag.type == :decimal
      assert flag.default == "3000.50"
    end

    test "creates a valid percentage flag" do
      flag = Flag.new!(key: "rate", type: :percentage, default: "50")

      assert flag.type == :percentage
      assert flag.default == "50"
    end

    test "creates a valid string flag" do
      flag = Flag.new!(key: "name", type: :string, default: "hello")

      assert flag.type == :string
      assert flag.default == "hello"
    end

    test "creates a valid secret flag with empty default" do
      flag = Flag.new!(key: "api_key", type: :secret)

      assert flag.type == :secret
      assert flag.default == ""
    end

    test "creates a valid secret flag with a seeded default" do
      flag = Flag.new!(key: "api_key", type: :secret, default: "placeholder")

      assert flag.type == :secret
      assert flag.default == "placeholder"
    end

    test "creates a valid select flag" do
      flag =
        Flag.new!(
          key: "provider",
          type: :select,
          default: "ses",
          options: [{"Mailjet", "mailjet"}, {"Amazon SES", "ses"}]
        )

      assert flag.type == :select
      assert flag.options == [{"Mailjet", "mailjet"}, {"Amazon SES", "ses"}]
    end

    test "raises on select without options" do
      assert_raise PhoenixFlags.Error, ~r/options is required/, fn ->
        Flag.new!(key: "provider", type: :select, default: "ses")
      end
    end

    test "raises on select default not in options" do
      assert_raise PhoenixFlags.Error, ~r/not in :options/, fn ->
        Flag.new!(
          key: "provider",
          type: :select,
          default: "invalid",
          options: [{"Mailjet", "mailjet"}]
        )
      end
    end

    test "raises on missing key" do
      assert_raise PhoenixFlags.Error, ~r/key/, fn ->
        Flag.new!(type: :boolean, default: "true")
      end
    end

    test "raises on empty key" do
      assert_raise PhoenixFlags.Error, ~r/non-empty string/, fn ->
        Flag.new!(key: "", type: :boolean, default: "true")
      end
    end

    test "raises on missing type" do
      assert_raise PhoenixFlags.Error, ~r/type/, fn ->
        Flag.new!(key: "test")
      end
    end

    test "raises on invalid type" do
      assert_raise PhoenixFlags.Error, ~r/must be one of/, fn ->
        Flag.new!(key: "test", type: :invalid, default: "x")
      end
    end

    test "raises on invalid boolean default" do
      assert_raise PhoenixFlags.Error, ~r/must be true or false/, fn ->
        Flag.new!(key: "test", type: :boolean, default: "yes")
      end
    end

    test "raises on invalid integer default" do
      assert_raise PhoenixFlags.Error, ~r/must be a whole number/, fn ->
        Flag.new!(key: "test", type: :integer, default: "abc")
      end
    end

    test "raises on invalid decimal default" do
      assert_raise PhoenixFlags.Error, ~r/must be a valid number/, fn ->
        Flag.new!(key: "test", type: :decimal, default: "not-a-number")
      end
    end

    test "raises on percentage default out of range" do
      assert_raise PhoenixFlags.Error, ~r/between 0 and 100/, fn ->
        Flag.new!(key: "test", type: :percentage, default: "150")
      end
    end

    test "raises on invalid percentage default" do
      assert_raise PhoenixFlags.Error, ~r/valid number/, fn ->
        Flag.new!(key: "test", type: :percentage, default: "abc")
      end
    end

    test "raises with helpful message when integer flag has no default" do
      assert_raise PhoenixFlags.Error, ~r/:default is required for :integer/, fn ->
        Flag.new!(key: "count", type: :integer)
      end
    end

    test "raises with helpful message when decimal flag has no default" do
      assert_raise PhoenixFlags.Error, ~r/:default is required for :decimal/, fn ->
        Flag.new!(key: "amount", type: :decimal)
      end
    end

    test "raises with helpful message when percentage flag has no default" do
      assert_raise PhoenixFlags.Error, ~r/:default is required for :percentage/, fn ->
        Flag.new!(key: "rate", type: :percentage)
      end
    end

    test "raises on a field longer than its 255-character column" do
      for field <- [:key, :label, :category, :description] do
        assert_raise PhoenixFlags.Error, ~r/:#{field} must be at most 255 characters/, fn ->
          Flag.new!(
            Keyword.merge([key: "k", type: :string], [{field, String.duplicate("é", 256)}])
          )
        end
      end

      assert Flag.new!(key: "k", type: :string, description: String.duplicate("é", 255))
    end

    test "raises on a field that is not a string" do
      assert_raise PhoenixFlags.Error, ~r/:label must be a string/, fn ->
        Flag.new!(key: "k", type: :string, label: :oops)
      end
    end

    test "raises PhoenixFlags.Error, not FunctionClauseError, on a non-string default" do
      assert_raise PhoenixFlags.Error, ~r/:default must be a string.*"5"/, fn ->
        Flag.new!(key: "k", type: :integer, default: 5)
      end
    end

    test "raises on a variant name that would not survive being stored" do
      for name <- [" a", "a ", "a,b", "a=b"] do
        assert_raise PhoenixFlags.Error, ~r/variant name/, fn ->
          Flag.new!(key: "k", type: :variant, variants: [{"A", name, 50}, {"B", "b", 50}])
        end
      end
    end
  end

  describe "use PhoenixFlags" do
    test "refuses a key declared twice" do
      assert_raise PhoenixFlags.Error, ~r/declares \["twice"\] more than once/, fn ->
        defmodule DuplicateKeys do
          use PhoenixFlags, otp_app: :phoenix_flags, repo: PhoenixFlags.TestRepo

          flag("twice", type: :boolean, default: "false")
          flag("twice", type: :string)
        end
      end
    end
  end

  describe "to_seed_map/1" do
    test "converts struct to seed map with string type" do
      flag = Flag.new!(key: "test", type: :boolean, default: "false", label: "Test Flag")
      map = Flag.to_seed_map(flag)

      assert map.key == "test"
      assert map.type == "boolean"
      assert map.value == "false"
      assert map.label == "Test Flag"
    end

    test "uses key as label when label is nil" do
      flag = Flag.new!(key: "my_flag", type: :string, default: "")
      map = Flag.to_seed_map(flag)

      assert map.label == "my_flag"
    end
  end
end
