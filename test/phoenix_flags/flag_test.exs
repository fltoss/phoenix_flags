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

    test "creates a valid select flag" do
      flag = Flag.new!(key: "provider", type: :select, default: "ses")

      assert flag.type == :select
    end

    test "raises on missing key" do
      assert_raise ArgumentError, ~r/key/, fn ->
        Flag.new!(type: :boolean, default: "true")
      end
    end

    test "raises on empty key" do
      assert_raise ArgumentError, ~r/non-empty string/, fn ->
        Flag.new!(key: "", type: :boolean, default: "true")
      end
    end

    test "raises on missing type" do
      assert_raise ArgumentError, ~r/type/, fn ->
        Flag.new!(key: "test")
      end
    end

    test "raises on invalid type" do
      assert_raise ArgumentError, ~r/must be one of/, fn ->
        Flag.new!(key: "test", type: :invalid, default: "x")
      end
    end

    test "raises on invalid boolean default" do
      assert_raise ArgumentError, ~r/must be "true" or "false"/, fn ->
        Flag.new!(key: "test", type: :boolean, default: "yes")
      end
    end

    test "raises on invalid integer default" do
      assert_raise ArgumentError, ~r/valid integer/, fn ->
        Flag.new!(key: "test", type: :integer, default: "abc")
      end
    end

    test "raises on invalid decimal default" do
      assert_raise ArgumentError, ~r/valid decimal/, fn ->
        Flag.new!(key: "test", type: :decimal, default: "not-a-number")
      end
    end

    test "raises on percentage default out of range" do
      assert_raise ArgumentError, ~r/between 0 and 100/, fn ->
        Flag.new!(key: "test", type: :percentage, default: "150")
      end
    end

    test "raises on invalid percentage default" do
      assert_raise ArgumentError, ~r/valid number/, fn ->
        Flag.new!(key: "test", type: :percentage, default: "abc")
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
