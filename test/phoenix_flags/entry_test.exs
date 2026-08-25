defmodule PhoenixFlags.EntryTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PhoenixFlags.Entry

  describe "cast_value/2" do
    test "nil stays nil for every type" do
      for type <- ~w(string boolean integer decimal percentage select secret) do
        assert Entry.cast_value(nil, type) == nil
      end
    end

    test "casts the two valid boolean values without logging" do
      log =
        capture_log(fn ->
          assert Entry.cast_value("true", "boolean") == true
          assert Entry.cast_value("false", "boolean") == false
        end)

      refute log =~ "failed to cast"
    end

    test "warns and fails closed on a boolean value that is neither true nor false" do
      log = capture_log(fn -> assert Entry.cast_value("yes", "boolean") == false end)

      assert log =~ ~s(failed to cast "yes" as boolean)
    end

    test "casts integers and warns on unparseable ones" do
      assert Entry.cast_value("42", "integer") == 42
      assert Entry.cast_value("-7", "integer") == -7

      log = capture_log(fn -> assert Entry.cast_value("42abc", "integer") == nil end)
      assert log =~ "failed to cast"
    end

    test "casts decimals and percentages and warns on unparseable ones" do
      assert Decimal.equal?(Entry.cast_value("3000.50", "decimal"), Decimal.new("3000.50"))
      assert Decimal.equal?(Entry.cast_value("50", "percentage"), Decimal.new("50"))

      log = capture_log(fn -> assert Entry.cast_value("abc", "decimal") == nil end)
      assert log =~ "failed to cast"
    end

    test "passes strings and selects through untouched" do
      assert Entry.cast_value("hello", "string") == "hello"
      assert Entry.cast_value("ses", "select") == "ses"
    end
  end

  describe "changeset/3" do
    defp entry(type, value) do
      %Entry{key: "k", type: type, value: value, category: "c", label: "l"}
    end

    test "only :value is writable" do
      changeset =
        Entry.changeset(entry("string", "old"), %{
          "value" => "new",
          "key" => "hacked",
          "type" => "boolean",
          "category" => "hacked"
        })

      assert changeset.changes == %{value: "new"}
    end

    test "treats \"\" as missing for non-secret types" do
      changeset = Entry.changeset(entry("string", "old"), %{"value" => ""})

      refute changeset.valid?
      assert {"can't be blank", _} = changeset.errors[:value]
    end

    test "accepts \"\" for a secret, as the way to clear it" do
      changeset = Entry.changeset(entry("secret", "ciphertext"), %{"value" => ""})

      assert changeset.valid?
      assert changeset.changes == %{value: ""}
    end

    test "skips the select membership check when no options are supplied" do
      assert Entry.changeset(entry("select", "a"), %{"value" => "anything"}).valid?
    end

    test "enforces the select membership check when options are supplied" do
      options = [{"A", "a"}, {"B", "b"}]

      assert Entry.changeset(entry("select", "a"), %{"value" => "b"}, select_options: options).valid?

      changeset =
        Entry.changeset(entry("select", "a"), %{"value" => "c"}, select_options: options)

      refute changeset.valid?
      assert {"must be one of: a, b", _} = changeset.errors[:value]
    end

    test "select options do not constrain a non-select entry" do
      changeset =
        Entry.changeset(entry("string", "x"), %{"value" => "c"}, select_options: [{"A", "a"}])

      assert changeset.valid?
    end
  end
end
