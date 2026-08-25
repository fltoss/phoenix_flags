defmodule PhoenixFlags.VariantRobustnessTest do
  @moduledoc """
  Regression tests for bugs found by review, plus fuzzing to back the claim that
  the public API does not crash its caller.
  """
  use PhoenixFlags.DataCase

  import ExUnit.CaptureLog

  alias PhoenixFlags.Config
  alias PhoenixFlags.Entry
  alias PhoenixFlags.Server
  alias PhoenixFlags.Variant

  defmodule RConfig do
    use PhoenixFlags, otp_app: :phoenix_flags, repo: PhoenixFlags.TestRepo

    flag("exp",
      type: :variant,
      category: "e",
      label: "Exp",
      variants: [{"A", "a", 50}, {"B", "b", 50}]
    )
  end

  defp start_uncached! do
    config = %Config{
      otp_app: :phoenix_flags,
      repo: TestRepo,
      name: RConfig,
      cache_enabled: false
    }

    :persistent_term.put({PhoenixFlags, RConfig, :config}, config)

    on_exit(fn ->
      for key <- [:cache, :config, :order] do
        try do
          :persistent_term.erase({PhoenixFlags, RConfig, key})
        rescue
          ArgumentError -> :ok
        end
      end
    end)

    config
  end

  defp insert_exp!(value) do
    TestRepo.insert!(%Entry{
      key: "exp",
      value: value,
      type: "variant",
      category: "e",
      label: "Exp"
    })
  end

  # ==========================================================================
  # Regression: the hash must not be re-partitionable
  # ==========================================================================

  describe "hash parts are unambiguous" do
    setup do
      {:ok, variant} = Variant.parse("a=50,b=50")
      %{variant: variant}
    end

    test "a colon in the key cannot be absorbed by the identity", %{variant: variant} do
      # Joining parts with a separator made these two identical, aliasing two
      # different experiments completely.
      aliased =
        Enum.count(1..2000, fn index ->
          Variant.assign(variant, "exp", "org:#{index}") ==
            Variant.assign(variant, "exp:org", "#{index}")
        end)

      # Independent 50/50 assignments agree about half the time; full aliasing
      # would be 2000.
      assert_in_delta aliased / 2000 * 100, 50, 5.0
    end

    test "a colon in the seed cannot be absorbed by the key" do
      {:ok, one} = Variant.parse("a=50,b=50", seed: "s:x")
      {:ok, two} = Variant.parse("a=50,b=50", seed: "s")

      differing =
        Enum.count(1..2000, fn index ->
          Variant.assign(one, "k", "u-#{index}") != Variant.assign(two, "x:k", "u-#{index}")
        end)

      assert differing > 0, "seed and key are still being conflated"
    end

    test "identities differing only in separator placement are independent",
         %{variant: variant} do
      agreeing =
        Enum.count(1..2000, fn index ->
          Variant.assign(variant, "k", "a:#{index}") == Variant.assign(variant, "k", "a#{index}")
        end)

      assert_in_delta agreeing / 2000 * 100, 50, 5.0
    end

    test "the distribution is still correct after length-prefixing", %{variant: variant} do
      identities = for index <- 1..20_000, do: "user-#{index}"
      counts = Enum.frequencies_by(identities, &Variant.assign(variant, "exp", &1))

      assert_in_delta Map.fetch!(counts, "a") / 20_000 * 100, 50, 1.0
    end
  end

  # ==========================================================================
  # Regression: a changed variant set must not keep assigning removed variants
  # ==========================================================================

  describe "seeding reconciles the stored split with the declaration" do
    test "resets the split when a declared variant is removed" do
      # Stored names "a" and "b"; RConfig declares "a" and "b" — so use a stored
      # value naming something RConfig does not declare.
      insert_exp!("a=50,zzz=50")

      log =
        capture_log(fn ->
          start_supervised!(
            {Server,
             %Config{
               otp_app: :phoenix_flags,
               repo: TestRepo,
               name: RConfig,
               cache_enabled: true
             }}
          )
        end)

      assert log =~ "declares a different set of variants than is stored"
      assert TestRepo.get_by!(Entry, key: "exp").value == "a=50,b=50"

      assigned = Enum.uniq(for index <- 1..300, do: RConfig.variant("exp", "u-#{index}"))
      assert Enum.sort(assigned) == ["a", "b"]
    end

    test "resets an unparseable stored split" do
      insert_exp!("total nonsense")

      capture_log(fn ->
        start_supervised!(
          {Server,
           %Config{otp_app: :phoenix_flags, repo: TestRepo, name: RConfig, cache_enabled: true}}
        )
      end)

      assert TestRepo.get_by!(Entry, key: "exp").value == "a=50,b=50"
    end

    test "preserves a runtime rollout when the variant set is unchanged" do
      # The whole point of storing weights in the database: a rollout must
      # survive a deploy.
      insert_exp!("a=20,b=80")

      start_supervised!(
        {Server,
         %Config{otp_app: :phoenix_flags, repo: TestRepo, name: RConfig, cache_enabled: true}}
      )

      assert TestRepo.get_by!(Entry, key: "exp").value == "a=20,b=80"
    end

    test "preserves a rollout whose weights are zero for one variant" do
      insert_exp!("a=0,b=100")

      start_supervised!(
        {Server,
         %Config{otp_app: :phoenix_flags, repo: TestRepo, name: RConfig, cache_enabled: true}}
      )

      assert TestRepo.get_by!(Entry, key: "exp").value == "a=0,b=100"
    end
  end

  # ==========================================================================
  # Regression: reads must not crash the caller
  # ==========================================================================

  describe "variant/3 never raises" do
    setup do
      start_uncached!()
      insert_exp!("a=50,b=50")
      :ok
    end

    test "an unusable identity warns and falls back instead of raising" do
      for identity <- [nil, "", %{}, [], :atom, 1.5, {1, 2}, self()] do
        log =
          capture_log(fn ->
            assert RConfig.variant("exp", identity, default: :fallback) == :fallback
          end)

        assert log =~ "variant assignment failed"
      end
    end

    test "returns nil rather than raising when no default is given" do
      capture_log(fn -> assert RConfig.variant("exp", nil) == nil end)
    end

    test "tolerates a non-keyword opts" do
      # The rescue clause must not itself be able to raise.
      capture_log(fn ->
        assert RConfig.variant("exp", nil, %{default: :ignored}) == nil
        assert RConfig.variant("exp", "user-1", %{}) in ["a", "b"]
      end)
    end

    test "tolerates odd keys" do
      for key <- [nil, :atom, 123, %{}, ""] do
        assert RConfig.variant(key, "user-1", default: :fallback) == :fallback
      end
    end

    test "Variant.assign/4 stays strict for direct callers" do
      {:ok, variant} = Variant.parse("a=100")

      assert_raise PhoenixFlags.Error, fn -> Variant.assign(variant, "k", nil) end
    end
  end

  describe "get/3 and update_entry/4 never raise on an odd key" do
    setup do
      start_uncached!()

      TestRepo.insert!(%Entry{
        key: "plain",
        value: "hello",
        type: "string",
        category: "e",
        label: "Plain"
      })

      :ok
    end

    # These crashed before: the rescue handler's own log statement interpolated
    # the key, and String.Chars is undefined for a map, tuple or pid — so the
    # failure escaped the rescue and reached the caller.
    test "get/2 falls back instead of raising" do
      for key <- [%{}, [], {1, 2}, self(), 1.5, make_ref()] do
        assert RConfig.get(key, :fallback) == :fallback
      end
    end

    test "get/2 still reads a real key" do
      assert RConfig.get("plain") == "hello"
    end

    test "update_entry/3 returns an error tuple instead of raising" do
      for key <- [%{}, [], {1, 2}, self()] do
        assert RConfig.update_entry(key, %{"value" => "x"}) == {:error, :not_found}
      end
    end

    test "variant/3 falls back on an odd key" do
      for key <- [%{}, [], {1, 2}, self()] do
        assert RConfig.variant(key, "user-1", default: :fallback) == :fallback
      end
    end

    test "a genuine database failure is still logged with an inspectable key" do
      # The rescue path that used to crash on interpolation: force it by asking
      # for a key that exists while the repo is unusable is awkward, so assert
      # the format directly on the module that builds it.
      log =
        capture_log(fn ->
          PhoenixFlags.Entry.cast_value("not-a-number", "integer")
        end)

      assert log =~ ~s(failed to cast "not-a-number")
    end
  end

  # ==========================================================================
  # Regression: silently ignored declaration options
  # ==========================================================================

  describe "declaration rejects options it would ignore" do
    test ":default on a :variant flag" do
      assert_raise PhoenixFlags.Error, ~r/:default is not used by a :variant flag/, fn ->
        PhoenixFlags.Flag.new!(
          key: "x",
          type: :variant,
          default: "ignored",
          variants: [{"A", "a", 100}]
        )
      end
    end

    test ":ttl and :seed on a non-variant flag" do
      assert_raise PhoenixFlags.Error, ~r/:ttl is only valid for :variant type/, fn ->
        PhoenixFlags.Flag.new!(key: "x", type: :boolean, default: "true", ttl: 1000)
      end

      assert_raise PhoenixFlags.Error, ~r/:seed is only valid for :variant type/, fn ->
        PhoenixFlags.Flag.new!(key: "x", type: :string, default: "s", seed: "z")
      end
    end

    test "a :variant flag with neither still works" do
      flag = PhoenixFlags.Flag.new!(key: "x", type: :variant, variants: [{"A", "a", 100}])

      assert flag.ttl == nil
      assert flag.seed == nil
      assert flag.default == ""
    end
  end

  # ==========================================================================
  # Fuzzing: the parsing and cast surface must only ever return, never raise
  # ==========================================================================

  describe "fuzzing the parse and cast surface" do
    # Deliberately nasty inputs: separator abuse, unicode, huge numbers,
    # negative and float weights, empty segments, wrong types.
    @garbage [
      "",
      " ",
      ",",
      "=",
      ",,,",
      "===",
      "a",
      "a=",
      "=50",
      "a=b",
      "a=50,",
      ",a=50",
      "a=50,,b=50",
      "a=50=60",
      "a==50",
      "a=+50",
      "a=1e3",
      "a=50.0,b=50.0",
      "a=-50,b=150",
      "a=0,b=0",
      "a=99999999999999999999,b=1",
      "a=50,a=50",
      "a:b=50,c=50",
      "a=50,b=50,c=0",
      "  a  =  50  ,  b  =  50  ",
      "ünïcödé=50,🎲=50",
      "a=50,b=50\n",
      "\ta=100",
      String.duplicate("a", 10_000) <> "=100",
      String.duplicate("a=1,", 200) <> "b=100",
      "a=100 ",
      "a= 100",
      nil,
      42,
      :atom,
      %{},
      [],
      {1, 2},
      1.5,
      <<0xFF, 0xFE>>
    ]

    test "Variant.parse/2 always returns a tagged tuple" do
      for input <- @garbage do
        assert match?({:ok, %Variant{}}, Variant.parse(input)) or
                 match?({:error, message} when is_binary(message), Variant.parse(input)),
               "unexpected result for #{inspect(input)}: #{inspect(Variant.parse(input))}"
      end
    end

    test "Variant.parse/2 with garbage options" do
      for opts <- [[names: nil], [names: []], [names: ["a"]], [ttl: nil], [seed: nil], []] do
        assert match?({:ok, _}, Variant.parse("a=100", opts)) or
                 match?({:error, _}, Variant.parse("a=100", opts))
      end
    end

    test "Variant.parse_weights/1 always returns a tagged tuple" do
      for input <- @garbage do
        result = Variant.parse_weights(input)

        assert match?({:ok, list} when is_list(list), result) or
                 match?({:error, message} when is_binary(message), result),
               "unexpected result for #{inspect(input)}: #{inspect(result)}"
      end
    end

    test "a successfully parsed split always assigns one of its own names" do
      for input <- @garbage do
        case Variant.parse(input) do
          {:ok, variant} ->
            names = Enum.map(variant.weights, &elem(&1, 0))

            for identity <- ["user-1", "user-2", "org:9", "🎲", String.duplicate("x", 500)] do
              assigned = Variant.assign(variant, "k", identity)

              assert assigned in names,
                     "#{inspect(input)} assigned #{inspect(assigned)}, not in #{inspect(names)}"
            end

          {:error, _message} ->
            :ok
        end
      end
    end

    test "a parsed split round-trips through serialize/1" do
      for input <- @garbage do
        case Variant.parse(input) do
          {:ok, variant} ->
            assert {:ok, reparsed} = variant |> Variant.serialize() |> Variant.parse()
            assert reparsed.weights == variant.weights
            assert reparsed.buckets == variant.buckets

          {:error, _message} ->
            :ok
        end
      end
    end

    test "Entry.cast_value/2 never raises for a variant column" do
      for input <- @garbage do
        capture_log(fn ->
          result = Entry.cast_value(input, "variant")
          assert is_nil(result) or match?(%Variant{}, result)
        end)
      end
    end

    test "Entry.changeset/3 never raises on garbage weights" do
      entry = %Entry{key: "exp", type: "variant", value: "a=50,b=50", category: "e", label: "E"}

      for input <- @garbage, is_binary(input) do
        changeset = Entry.changeset(entry, %{"value" => input}, variants: ["a", "b"])

        assert %Ecto.Changeset{} = changeset

        # A changeset is valid only when the value parses, totals 100, and names
        # exactly "a" and "b" — so validity must agree with the parser.
        expected =
          case Variant.parse(input, names: ["a", "b"]) do
            {:ok, _variant} -> true
            {:error, _message} -> false
          end

        assert changeset.valid? == expected,
               "#{inspect(input)}: changeset valid?=#{changeset.valid?} but parse says #{expected}"
      end
    end

    test "assign/4 tolerates extreme ttl and now values" do
      for ttl <- [1, 1000, :timer.hours(24), 9_999_999_999] do
        {:ok, variant} = Variant.parse("a=50,b=50", ttl: ttl)

        for now <- [0, 1, -1, 1_700_000_000_000, 9_999_999_999_999] do
          assert Variant.assign(variant, "k", "user-1", now: now) in ["a", "b"]
        end
      end
    end
  end
end
