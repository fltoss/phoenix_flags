# Benchmarks for PhoenixFlags public API
#
# Run with: mix run bench/phoenix_flags_bench.exs
#
# This measures the performance of each public function, with separate
# benchmarks for cached reads (persistent_term) vs DB reads to quantify
# the caching layer's impact.
#
# I/O profile per function:
#
#   get/2 (cached)     → 0 DB calls, 0 network calls (persistent_term only)
#   get/2 (uncached)   → 1 DB call  (SELECT by key)
#   all_grouped/0      → 0 DB calls when cached, 1 SELECT ALL when uncached
#   flags/0            → 0 DB calls (compiled module attribute)
#   select_options/1   → 0 DB calls (compiled module attribute)
#   variant/3          → 0 DB calls (persistent_term + SHA-256 + bucket walk)
#   get/3 w/ targeting → 0 DB calls (one extra persistent_term read + rule walk)
#   update_entry/3     → 2 DB calls (SELECT by key + UPDATE), cache patched in-memory
#                        + N network sends (Node.list peer notification, fire-and-forget)

Code.require_file("bench/bench_helper.exs")

alias PhoenixFlags.{Config, Server}

repo = PhoenixFlags.TestRepo

# =============================================================================
# Setup: define a benchmark config module with several flag types
# =============================================================================

defmodule BenchConfig do
  use PhoenixFlags,
    otp_app: :phoenix_flags,
    repo: PhoenixFlags.TestRepo

  flag("bench_bool", type: :boolean, default: "true", category: "alpha", label: "Bool Flag")
  flag("bench_int", type: :integer, default: "42", category: "alpha", label: "Int Flag")
  flag("bench_str", type: :string, default: "hello", category: "beta", label: "String Flag")
  flag("bench_dec", type: :decimal, default: "99.99", category: "beta", label: "Decimal Flag")
  flag("bench_pct", type: :percentage, default: "50", category: "gamma", label: "Pct Flag")

  flag("bench_sel",
    type: :select,
    default: "a",
    category: "gamma",
    label: "Select Flag",
    options: [{"Option A", "a"}, {"Option B", "b"}]
  )

  flag("bench_var",
    type: :variant,
    category: "delta",
    label: "Variant Flag",
    variants: [{"Control", "control", 50}, {"Treatment", "treatment", 50}]
  )

  flag("bench_var_ttl",
    type: :variant,
    category: "delta",
    label: "Variant Flag (24h TTL)",
    ttl: :timer.hours(24),
    variants: [{"Control", "control", 50}, {"Treatment", "treatment", 50}]
  )
end

# Start GenServer with cache enabled (production mode)
cached_config = %Config{
  otp_app: :phoenix_flags,
  repo: repo,
  name: BenchConfig,
  cache_enabled: true
}

{:ok, _pid} = Server.start_link(cached_config)

# Verify setup
true = BenchConfig.get("bench_bool")
42 = BenchConfig.get("bench_int")

IO.puts("""
\n#{String.duplicate("=", 70)}
PhoenixFlags Benchmark Suite
#{String.duplicate("=", 70)}
Flags seeded: #{length(BenchConfig.flags())}
Cache: persistent_term (production mode)
#{String.duplicate("=", 70)}
""")

# =============================================================================
# 1. Individual function benchmarks (cached — production mode)
# =============================================================================

IO.puts("--- 1. get/2 by type [0 DB calls, persistent_term read] ---\n")

Benchee.run(
  %{
    "get/2 boolean" => fn -> BenchConfig.get("bench_bool") end,
    "get/2 integer" => fn -> BenchConfig.get("bench_int") end,
    "get/2 string" => fn -> BenchConfig.get("bench_str") end,
    "get/2 decimal" => fn -> BenchConfig.get("bench_dec") end,
    "get/2 percentage" => fn -> BenchConfig.get("bench_pct") end,
    "get/2 select" => fn -> BenchConfig.get("bench_sel") end,
    "get/2 missing (default)" => fn -> BenchConfig.get("nonexistent", :fallback) end
  },
  time: 3,
  warmup: 1,
  memory_time: 1,
  print: [configuration: false]
)

IO.puts("\n--- 2. all_grouped/0 [0 DB calls, persistent_term read + sort/group] ---\n")

Benchee.run(
  %{
    "all_grouped/0" => fn -> BenchConfig.all_grouped() end
  },
  time: 3,
  warmup: 1,
  memory_time: 1,
  print: [configuration: false]
)

IO.puts("\n--- 3. flags/0 [0 DB calls, compiled module attribute] ---\n")

Benchee.run(
  %{
    "flags/0" => fn -> BenchConfig.flags() end
  },
  time: 3,
  warmup: 1,
  memory_time: 1,
  print: [configuration: false]
)

IO.puts("\n--- 4. select_options/1 [0 DB calls, compiled module attribute + list scan] ---\n")

Benchee.run(
  %{
    "select_options/1 (select flag)" => fn -> BenchConfig.select_options("bench_sel") end,
    "select_options/1 (non-select)" => fn -> BenchConfig.select_options("bench_bool") end
  },
  time: 3,
  warmup: 1,
  memory_time: 1,
  print: [configuration: false]
)

IO.puts("\n--- 4b. variant/3 [0 DB calls, persistent_term + SHA-256 + bucket walk] ---\n")

Benchee.run(
  %{
    "variant/3 (ttl: nil)" => fn -> BenchConfig.variant("bench_var", "user-12345") end,
    "variant/3 (ttl: 24h)" => fn -> BenchConfig.variant("bench_var_ttl", "user-12345") end,
    "variant/3 (integer identity)" => fn -> BenchConfig.variant("bench_var", 12_345) end,
    "variant/3 (+ telemetry)" => fn ->
      BenchConfig.variant("bench_var", "user-12345", telemetry: true)
    end,
    "variants/1 (declaration lookup)" => fn -> BenchConfig.variants("bench_var") end
  },
  time: 3,
  warmup: 1,
  memory_time: 1,
  print: [configuration: false]
)

IO.puts("\n--- 4c. targeting [0 DB calls, one extra persistent_term read + rule walk] ---\n")

{:ok, _} =
  BenchConfig.put_target("bench_bool",
    conditions: [[attribute: :company_id, operator: :in, values: [123]]],
    value: "false"
  )

# Context is set once per scenario, so only the read is timed. Comparing separate
# Benchee runs at this timescale is not reliable -- everything that needs
# comparing has to sit in one run.
set_context = fn attrs ->
  fn _input ->
    if attrs == [], do: PhoenixFlags.clear_context(), else: PhoenixFlags.put_context(attrs)
  end
end

Benchee.run(
  %{
    "get/2 no context, flag has no rules" =>
      {fn _ -> BenchConfig.get("bench_str") end, before_scenario: set_context.([])},
    "get/2 context set, flag has no rules" =>
      {fn _ -> BenchConfig.get("bench_str") end, before_scenario: set_context.(company_id: 999)},
    "get/2 context set, rule misses" =>
      {fn _ -> BenchConfig.get("bench_bool") end, before_scenario: set_context.(company_id: 999)},
    "get/2 context set, rule matches" =>
      {fn _ -> BenchConfig.get("bench_bool") end, before_scenario: set_context.(company_id: 123)}
  },
  time: 3,
  warmup: 1,
  memory_time: 1,
  print: [configuration: false]
)

PhoenixFlags.clear_context()

IO.puts("""
\n--- 5. update_entry/3 [2 DB calls: SELECT + UPDATE, cache patched in-memory] ---
       [+ N network sends to Node.list() peers, fire-and-forget]
""")

Benchee.run(
  %{
    "update_entry/3 boolean (×2)" => fn ->
      BenchConfig.update_entry("bench_bool", %{"value" => "false"})
      BenchConfig.update_entry("bench_bool", %{"value" => "true"})
    end,
    "update_entry/3 string (×2)" => fn ->
      BenchConfig.update_entry("bench_str", %{"value" => "world"})
      BenchConfig.update_entry("bench_str", %{"value" => "hello"})
    end
  },
  time: 5,
  warmup: 1,
  memory_time: 1,
  print: [configuration: false]
)

# =============================================================================
# 2. Cache vs DB comparison — shows the cost of network I/O
# =============================================================================

IO.puts("""
\n#{String.duplicate("=", 70)}
Cache vs Direct DB Read Comparison
#{String.duplicate("=", 70)}
This section runs the same functions with cache_enabled: false to show
the cost of each DB round-trip vs the zero-cost persistent_term cache.
""")

# Stop the cached server
GenServer.stop(BenchConfig)

for key <- [:cache, :config, :order] do
  try do
    :persistent_term.erase({PhoenixFlags, BenchConfig, key})
  rescue
    ArgumentError -> :ok
  end
end

# We need both modes running. Use a second module for cached reads.
defmodule BenchConfigCached do
  use PhoenixFlags,
    otp_app: :phoenix_flags,
    repo: PhoenixFlags.TestRepo

  flag("bench_bool", type: :boolean, default: "true", category: "alpha", label: "Bool Flag")
  flag("bench_int", type: :integer, default: "42", category: "alpha", label: "Int Flag")
  flag("bench_str", type: :string, default: "hello", category: "beta", label: "String Flag")
  flag("bench_dec", type: :decimal, default: "99.99", category: "beta", label: "Decimal Flag")
  flag("bench_pct", type: :percentage, default: "50", category: "gamma", label: "Pct Flag")

  flag("bench_sel",
    type: :select,
    default: "a",
    category: "gamma",
    label: "Select Flag",
    options: [{"Option A", "a"}, {"Option B", "b"}]
  )

  flag("bench_var",
    type: :variant,
    category: "delta",
    label: "Variant Flag",
    variants: [{"Control", "control", 50}, {"Treatment", "treatment", 50}]
  )

  flag("bench_var_ttl",
    type: :variant,
    category: "delta",
    label: "Variant Flag (24h TTL)",
    ttl: :timer.hours(24),
    variants: [{"Control", "control", 50}, {"Treatment", "treatment", 50}]
  )
end

cached_config2 = %Config{
  otp_app: :phoenix_flags,
  repo: repo,
  name: BenchConfigCached,
  cache_enabled: true
}

{:ok, _pid} = Server.start_link(cached_config2)

# Start BenchConfig uncached (every read hits DB)
uncached_config = %Config{
  otp_app: :phoenix_flags,
  repo: repo,
  name: BenchConfig,
  cache_enabled: false
}

{:ok, _pid} = Server.start_link(uncached_config)

IO.puts("--- 6. get/2: cached [0 DB] vs uncached [1 DB: SELECT by key] ---\n")

Benchee.run(
  %{
    "get/2 cached (persistent_term)" => fn -> BenchConfigCached.get("bench_bool") end,
    "get/2 uncached (DB query)" => fn -> BenchConfig.get("bench_bool") end
  },
  time: 5,
  warmup: 1,
  memory_time: 1,
  print: [configuration: false]
)

IO.puts("\n--- 7. all_grouped/0: cached [0 DB] vs uncached [1 DB: SELECT ALL] ---\n")

Benchee.run(
  %{
    "all_grouped/0 cached" => fn -> BenchConfigCached.all_grouped() end,
    "all_grouped/0 uncached (DB)" => fn -> BenchConfig.all_grouped() end
  },
  time: 5,
  warmup: 1,
  memory_time: 1,
  print: [configuration: false]
)

# =============================================================================
# 3. Comprehensive workflow benchmark
# =============================================================================

IO.puts("""
\n#{String.duplicate("=", 70)}
Comprehensive Workflow: Full Read-Update-Read Cycle
#{String.duplicate("=", 70)}
Simulates a typical admin dashboard interaction:
  6× get/2 reads + all_grouped/0 + update_entry/3 + get/2 + restore
Total DB calls per iteration: 4 (all from the 2 update_entry calls)
""")

Benchee.run(
  %{
    "full cycle (cached)" => fn ->
      # Read all flags (0 DB calls — all from persistent_term)
      BenchConfigCached.get("bench_bool")
      BenchConfigCached.get("bench_int")
      BenchConfigCached.get("bench_str")
      BenchConfigCached.get("bench_dec")
      BenchConfigCached.get("bench_pct")
      BenchConfigCached.get("bench_sel")
      # Get grouped view (0 DB calls)
      BenchConfigCached.all_grouped()
      # Update a flag (2 DB calls: SELECT + UPDATE, cache patched in-memory)
      BenchConfigCached.update_entry("bench_bool", %{"value" => "false"})
      # Read updated value (0 DB calls)
      BenchConfigCached.get("bench_bool")
      # Restore (2 DB calls: SELECT + UPDATE)
      BenchConfigCached.update_entry("bench_bool", %{"value" => "true"})
    end
  },
  time: 5,
  warmup: 1,
  memory_time: 1,
  print: [configuration: false]
)

# Cleanup
GenServer.stop(BenchConfigCached)
GenServer.stop(BenchConfig)

IO.puts("\nBenchmark complete.")
