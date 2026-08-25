# Benchmarks

Performance characteristics of PhoenixFlags public API.

Run benchmarks yourself:

```bash
mix run bench/phoenix_flags_bench.exs
```

## Environment

- Elixir 1.20.0-rc.3 / OTP 27
- PostgreSQL (local)
- 8 flags across 4 categories (boolean, integer, string, decimal, percentage, select, and two variant flags)

## I/O Profile

Each function's database and network call count per invocation:

| Function | DB Calls | Network Calls | Notes |
|---|---|---|---|
| `get/2` (cached) | 0 | 0 | `persistent_term.get` + `Map.get` |
| `get/2` (uncached) | 1 | 0 | `SELECT ... WHERE key = $1` |
| `all_grouped/0` (cached) | 0 | 0 | `persistent_term.get` + sort/group in memory |
| `all_grouped/0` (uncached) | 1 | 0 | `SELECT` all entries |
| `flags/0` | 0 | 0 | Compiled module attribute |
| `select_options/1` | 0 | 0 | `flags/0` + list scan |
| `variant/3` | 0 | 0 | `persistent_term.get` + SHA-256 + bucket walk |
| `variants/1` | 0 | 0 | Compiled module attribute + list scan |
| `update_entry/3` | 2 | N | `SELECT` by key + `UPDATE` (cache patched in-memory) |

`update_entry/3` also sends a fire-and-forget `:reload` message to `Node.list()` peers (N = number of connected nodes). Each peer then performs 1 DB call (`SELECT` all) to reload its local cache.

## Results

### 1. Cached reads — `get/2`

Zero DB calls. Reads from `:persistent_term` + `Map.get`.

| Scenario | ips | avg | median | 99th % | memory |
|---|---|---|---|---|---|
| `get/2` boolean | 7.61 M | 131 ns | 98 ns | 232 ns | 88 B |
| `get/2` integer | 6.04 M | 166 ns | 122 ns | 318 ns | 88 B |
| `get/2` string | 5.30 M | 189 ns | 130 ns | 347 ns | 88 B |
| `get/2` decimal | 6.34 M | 158 ns | 107 ns | 277 ns | 88 B |
| `get/2` percentage | 6.29 M | 159 ns | 117 ns | 302 ns | 88 B |
| `get/2` select | 6.15 M | 162 ns | 124 ns | 315 ns | 88 B |
| `get/2` missing key | 6.44 M | 155 ns | 120 ns | 294 ns | 88 B |

All types perform identically at ~100-130 ns median. The value is already cast and stored in a map — `get/2` does no type conversion at read time.

### 2. `all_grouped/0` (cached)

Zero DB calls. Reads entries from `:persistent_term`, sorts by pre-computed declaration order, groups by category.

| Scenario | ips | avg | median | 99th % | memory |
|---|---|---|---|---|---|
| `all_grouped/0` | 713 K | 1.40 us | 1.25 us | 4.46 us | 1.73 KB |

The flag ordering index is pre-computed once at startup and stored in persistent_term, avoiding per-call `flags() |> Enum.with_index()` overhead.

### 3. `flags/0` (compiled)

Zero DB calls. Returns a compiled list of `%PhoenixFlags.Flag{}` structs.

| Scenario | ips | avg | median | 99th % | memory |
|---|---|---|---|---|---|
| `flags/0` | 28.96 M | 35 ns | 31 ns | 65 ns | 96 B |

Fastest function — returns a module attribute.

### 4. `select_options/1`

Zero DB calls. Scans the `flags/0` list for a matching key.

| Scenario | ips | avg | median | 99th % | memory |
|---|---|---|---|---|---|
| `select_options/1` (select) | 5.11 M | 196 ns | 145 ns | 342 ns | 120 B |
| `select_options/1` (non-select) | 9.00 M | 111 ns | 63 ns | 152 ns | 120 B |

### 4b. `variant/3` — A/B assignment

Zero DB calls. The split is parsed once when the cache loads, so a call is a
`:persistent_term` read, one SHA-256, and a walk of the cumulative bucket list.

> Measured separately from the sections above, on Elixir 1.20.3 / OTP 29 on a
> loaded development machine. Figures are rounded and should be read as orders
> of magnitude — repeat runs varied by up to 3x on the same code, and Benchee
> reports deviations above 1000% at this timescale. The call-count column in the
> I/O profile above is the part that is exact.

| Scenario | ips | median | notes |
|---|---|---|---|
| `variants/1` (declaration lookup) | ~5 M | ~0.16 us | compiled attribute + list scan |
| `variant/3` (`ttl: nil`) | ~1.5 M | ~0.55 us | one SHA-256 |
| `variant/3` (`ttl: 24h`) | ~1.0 M | ~0.90 us | a second hash for the per-identity offset, plus a clock read |
| `variant/3` (`telemetry: true`) | ~0.8 M | ~0.90 us | adds `:telemetry.execute/3` |

`variant/3` is roughly 5-7x the cost of `get/2`, which is the SHA-256. That is
deliberate: `:erlang.phash2/2` would be cheaper but is not guaranteed stable
across OTP major versions, and an OTP upgrade silently reshuffling every live
experiment is a far worse outcome than ~0.5 us per assignment. At ~1.5 M
assignments/sec it is not a bottleneck for request-path use.

Setting `ttl:` roughly doubles the cost, so leave it `nil` (the default) unless
you actually want assignments to expire.

### 5. `update_entry/3` (DB write + incremental cache patch)

2 DB calls per update: `SELECT` by key + `UPDATE`. Cache is patched in-memory (no reload query).

| Scenario | ips | avg | median | 99th % | memory |
|---|---|---|---|---|---|
| `update_entry/3` boolean (x2) | 528 | 1.89 ms | 1.85 ms | 2.61 ms | 1.08 KB |
| `update_entry/3` string (x2) | 527 | 1.90 ms | 1.86 ms | 2.62 ms | 1.08 KB |

Each benchmark iteration performs 2 updates (toggle + restore), so a single `update_entry/3` takes ~0.95 ms. The cost is dominated by DB round-trips (SELECT + UPDATE). The cache reload `SELECT ALL` was eliminated by patching the persistent_term tuple in-memory.

### 6. Cache vs DB: `get/2`

Head-to-head comparison of cached (persistent_term) vs uncached (direct DB query) reads.

| Scenario | ips | avg | median | 99th % | memory |
|---|---|---|---|---|---|
| `get/2` cached | 7.06 M | 0.14 us | 0.098 us | 0.25 us | 88 B |
| `get/2` uncached (DB) | 16.3 K | 61 us | 53 us | 149 us | 13.9 KB |

**Cached reads are ~500x faster and use ~160x less memory** than direct DB queries.

### 7. Cache vs DB: `all_grouped/0`

| Scenario | ips | avg | median | 99th % | memory |
|---|---|---|---|---|---|
| `all_grouped/0` cached | 723 K | 1.38 us | 1.18 us | 3.72 us | 1.75 KB |
| `all_grouped/0` uncached (DB) | 14.6 K | 69 us | 63 us | 117 us | 29.2 KB |

**Cached is ~50x faster and uses ~17x less memory.**

### 8. Full workflow cycle

Simulates a dashboard interaction: 6 reads + grouped view + update + read + restore.

| Scenario | ips | avg | median | 99th % | memory |
|---|---|---|---|---|---|
| Full cycle (cached) | 319 | 3.13 ms | 2.33 ms | 5.95 ms | 4.01 KB |

Of the total time, the 8 cached reads contribute <2 us combined. The remaining time is entirely from the 2 `update_entry/3` DB round-trips (4 DB calls total).

## Summary

| Operation | Latency | DB Calls | Bottleneck |
|---|---|---|---|
| Read (cached) | ~100 ns | 0 | None (in-memory) |
| Read (uncached) | ~60 us | 1 | DB round-trip |
| Grouped view (cached) | ~1.3 us | 0 | Sort + group |
| Grouped view (uncached) | ~63 us | 1 | DB round-trip |
| Write | ~0.95 ms | 2 | DB round-trips (SELECT + UPDATE) |
| Flag metadata | ~30-150 ns | 0 | None (compiled) |

Reads are zero-cost in production. Writes are intentionally slow (database is source of truth) and only happen during admin configuration changes.
