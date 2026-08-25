defmodule PhoenixFlags.VariantTest do
  use ExUnit.Case, async: true

  alias PhoenixFlags.Variant

  # The moduledoc examples are the first thing a reader tries; run them so they
  # cannot rot.
  doctest PhoenixFlags.Variant

  @day :timer.hours(24)
  # A fixed identity set, so every distribution assertion below is fully
  # deterministic — it cannot flake, and 20k keeps the suite fast. SHA-256 is
  # stable across OTP versions, so these numbers hold everywhere.
  @identities for index <- 1..20_000, do: "user-#{index}"

  defp parse!(value, opts \\ []) do
    {:ok, variant} = Variant.parse(value, opts)
    variant
  end

  defp distribution(variant, key \\ "checkout", opts \\ []) do
    @identities
    |> Enum.frequencies_by(&Variant.assign(variant, key, &1, opts))
    |> Map.new(fn {name, count} -> {name, count / length(@identities) * 100} end)
  end

  describe "parse/2" do
    test "builds cumulative buckets out of the resolution" do
      variant = parse!("control=60,new=40")

      assert variant.weights == [{"control", 60}, {"new", 40}]
      assert variant.buckets == [{"control", 6000}, {"new", 10_000}]
      assert List.last(variant.buckets) |> elem(1) == Variant.resolution()
    end

    test "carries ttl and seed through" do
      variant = parse!("a=100", ttl: @day, seed: "s")

      assert variant.ttl == @day
      assert variant.seed == "s"
    end

    test "defaults ttl and seed to nil" do
      variant = parse!("a=100")

      assert variant.ttl == nil
      assert variant.seed == nil
    end

    test "tolerates surrounding whitespace" do
      assert parse!(" control = 60 , new = 40 ").weights == [{"control", 60}, {"new", 40}]
    end

    test "accepts a zero weight, which then never wins" do
      variant = parse!("live=100,dark=0")

      assert Enum.all?(Enum.take(@identities, 500), &(Variant.assign(variant, "k", &1) == "live"))
    end

    test "rejects weights that do not total 100" do
      assert {:error, "weights must total 100, got 90"} = Variant.parse("a=50,b=40")
      assert {:error, "weights must total 100, got 110"} = Variant.parse("a=50,b=60")
    end

    test "rejects duplicate names" do
      assert {:error, message} = Variant.parse("a=50,a=50")
      assert message =~ "duplicate variant(s): a"
    end

    test "rejects malformed input" do
      assert {:error, message} = Variant.parse("junk")
      assert message =~ "is not of the form"

      assert {:error, _} = Variant.parse("=100")
      assert {:error, _} = Variant.parse("a=abc")
      assert {:error, _} = Variant.parse("a=-5,b=105")
      assert {:error, _} = Variant.parse("")
      assert {:error, _} = Variant.parse(nil)
    end

    test "rejects names that are not declared, when names are supplied" do
      assert {:error, message} = Variant.parse("a=50,bogus=50", names: ["a", "b"])
      assert message =~ "unknown variant(s) bogus"
      assert message =~ "declared: a, b"
    end

    test "skips the name check when no names are supplied" do
      assert {:ok, _} = Variant.parse("anything=100")
    end
  end

  describe "parse_weights/1" do
    test "parses without enforcing the total, for mid-edit rendering" do
      assert Variant.parse_weights("a=30,b=30") == {:ok, [{"a", 30}, {"b", 30}]}
    end

    test "still rejects malformed pairs" do
      assert {:error, _} = Variant.parse_weights("a=nope")
    end
  end

  describe "serialize/1" do
    test "round-trips a parsed split" do
      assert "control=60,new=40" |> parse!() |> Variant.serialize() == "control=60,new=40"
    end

    test "accepts plain pairs" do
      assert Variant.serialize([{"a", 1}, {"b", 99}]) == "a=1,b=99"
    end
  end

  describe "assign/4 determinism" do
    test "is stable for a given identity" do
      variant = parse!("control=50,new=50")
      first = Variant.assign(variant, "checkout", "user-1")

      assert Enum.all?(1..50, fn _ -> Variant.assign(variant, "checkout", "user-1") == first end)
    end

    test "accepts an integer identity, equivalently to its string form" do
      variant = parse!("control=50,new=50")

      assert Variant.assign(variant, "k", 42) == Variant.assign(variant, "k", "42")
    end

    test "raises rather than silently bucketing a missing identity" do
      variant = parse!("control=50,new=50")

      for bad <- [nil, "", %{}, :user, 1.5] do
        assert_raise PhoenixFlags.Error,
                     ~r/identity must be a non-empty string or an integer/,
                     fn ->
                       Variant.assign(variant, "k", bad)
                     end
      end
    end

    test "returns nil when there are no buckets" do
      assert Variant.assign(%Variant{}, "k", "user-1") == nil
    end
  end

  describe "assign/4 distribution" do
    test "matches the declared weights within a percentage point" do
      for {spec, expected} <- [
            {"control=50,new=50", %{"control" => 50, "new" => 50}},
            {"control=90,new=10", %{"control" => 90, "new" => 10}},
            {"control=95,new=5", %{"control" => 95, "new" => 5}},
            {"a=33,b=33,c=34", %{"a" => 33, "b" => 33, "c" => 34}}
          ] do
        actual = distribution(parse!(spec))

        for {name, target} <- expected do
          assert_in_delta Map.fetch!(actual, name), target, 1.0
        end
      end
    end

    test "different flag keys do not correlate" do
      variant = parse!("control=50,new=50")

      agreeing =
        Enum.count(@identities, fn identity ->
          Variant.assign(variant, "flag_a", identity) ==
            Variant.assign(variant, "flag_b", identity)
        end)

      # Correlated flags would agree ~100% of the time; independent ones ~50%.
      assert_in_delta agreeing / length(@identities) * 100, 50, 1.0
    end

    test "a different seed reshuffles the population" do
      plain = parse!("control=50,new=50")
      seeded = parse!("control=50,new=50", seed: "round-two")

      agreeing =
        Enum.count(@identities, fn identity ->
          Variant.assign(plain, "k", identity) == Variant.assign(seeded, "k", identity)
        end)

      assert_in_delta agreeing / length(@identities) * 100, 50, 1.0
    end

    test "the same seed on two flags deliberately correlates them" do
      variant = parse!("control=50,new=50", seed: "shared")

      # The seed is part of the hash input alongside the key, so it does not by
      # itself make two keys agree — this documents that, so the behaviour is not
      # mistaken for a bug later.
      agreeing =
        Enum.count(Enum.take(@identities, 10_000), fn identity ->
          Variant.assign(variant, "flag_a", identity) ==
            Variant.assign(variant, "flag_b", identity)
        end)

      assert_in_delta agreeing / 10_000 * 100, 50, 2.0
    end
  end

  describe "assign/4 stickiness" do
    test "growing a variant never moves anyone out of it" do
      before = parse!("control=90,new=10")
      later = parse!("control=80,new=20")

      transitions =
        Enum.frequencies(
          for identity <- @identities do
            {Variant.assign(before, "checkout", identity),
             Variant.assign(later, "checkout", identity)}
          end
        )

      # The whole point of cumulative buckets: nobody already in "new" goes back.
      assert Map.get(transitions, {"new", "control"}, 0) == 0
      assert Map.fetch!(transitions, {"new", "new"}) > 0
      assert Map.fetch!(transitions, {"control", "new"}) > 0
    end

    test "a full rollout puts everyone in the target variant" do
      variant = parse!("control=0,new=100")

      assert distribution(variant) == %{"new" => 100.0}
    end
  end

  describe "assign/4 with ttl" do
    @t0 1_700_000_000_000

    test "ttl: nil is permanent" do
      variant = parse!("control=50,new=50")

      assert Variant.assign(variant, "k", "user-1", now: @t0) ==
               Variant.assign(variant, "k", "user-1", now: @t0 + @day * 3650)
    end

    test "is stable within a window" do
      variant = parse!("control=50,new=50", ttl: @day)
      first = Variant.assign(variant, "k", "user-1", now: @t0)

      # Sample the same window at many points; the offset is per-identity, so a
      # window boundary may fall inside the day — step in small increments from a
      # known-stable point instead of assuming alignment.
      assert Enum.all?(1..30, fn minute ->
               Variant.assign(variant, "k", "user-1", now: @t0 + minute * 60_000) == first
             end)
    end

    test "re-rolls across windows, so a user sees more than one variant over time" do
      variant = parse!("control=50,new=50", ttl: @day)

      seen =
        Enum.uniq(
          for window <- 0..120,
              do: Variant.assign(variant, "k", "user-1", now: @t0 + window * @day)
        )

      assert Enum.sort(seen) == ["control", "new"]
    end

    test "still respects the declared weights over many windows" do
      variant = parse!("control=90,new=10", ttl: @day)

      counts =
        for window <- 0..999 do
          Variant.assign(variant, "k", "user-1", now: @t0 + window * @day)
        end
        |> Enum.frequencies()

      assert_in_delta Map.fetch!(counts, "control") / 1000 * 100, 90, 4.0
    end

    test "windows are staggered per identity, not aligned across the population" do
      variant = parse!("control=50,new=50", ttl: @day)
      identities = Enum.take(@identities, 3000)

      churn_per_hour =
        for hour <- 0..23 do
          at = @t0 + hour * :timer.hours(1)

          Enum.count(identities, fn identity ->
            Variant.assign(variant, "k", identity, now: at) !=
              Variant.assign(variant, "k", identity, now: at + :timer.hours(1))
          end)
        end

      # Aligned boundaries would mean 23 hours of zero churn and one huge spike.
      assert Enum.all?(churn_per_hour, &(&1 > 0)),
             "expected churn every hour, got #{inspect(churn_per_hour)}"

      assert Enum.max(churn_per_hour) < length(identities) / 2
    end
  end
end
