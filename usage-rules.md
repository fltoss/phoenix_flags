# PhoenixFlags Usage Rules

PhoenixFlags provides database-backed, cached, cluster-aware system configuration for Phoenix applications.

## Setup

1. Define a configuration module:

```elixir
defmodule MyApp.SystemConfig do
  use PhoenixFlags,
    otp_app: :my_app,
    repo: MyApp.Repo

  def benefits_enabled?, do: get("enable_benefits", false)
end
```

2. Add it to your supervision tree **after** your Repo:

```elixir
children = [
  MyApp.Repo,
  MyApp.SystemConfig
]
```

## Reading config values

- `MyApp.SystemConfig.get("key")` — returns the cached value or `nil`
- `MyApp.SystemConfig.get("key", default)` — returns the cached value or `default`
- `MyApp.SystemConfig.all_grouped()` — returns all entries grouped by category

Reads are zero-copy from `:persistent_term` — no GenServer calls, no ETS lookups.

## A/B testing (`:variant` flags)

A `:variant` flag has no single value — it resolves per caller. Declare weighted
variants that total 100:

```elixir
flag "checkout_flow",
  type: :variant,
  category: "experiments",
  label: "Checkout flow",
  ttl: nil,                    # nil (default) = assignment never expires
  variants: [{"Control", "control", 90}, {"New flow", "new_flow", 10}]
```

- `MyApp.SystemConfig.variant("checkout_flow", user.id)` — the variant for that identity
- `MyApp.SystemConfig.variant("key", id, default: "control")` — fallback if the flag is missing
- `MyApp.SystemConfig.variant("key", id, telemetry: true)` — also emit `[:phoenix_flags, :variant, :assigned]`
- `MyApp.SystemConfig.variants("key")` — the declared `{label, value, weight}` list

Rules:

- Use `variant/3`, **not** `get/2` — `get/2` raises for a `:variant` flag.
- The identity must be a non-empty string or an integer. `nil` raises, because it
  would put every caller in the same bucket.
- Assignment is deterministic: same identity + same split = same variant, on
  every node and across restarts.
- Change the split at runtime (dashboard or `update_entry/3`) with a
  `"name=weight,..."` string whose weights total 100. Growing a variant at the
  expense of the next one does not move anyone already in it.
- Set `ttl:` in milliseconds to re-roll each caller once per window; windows are
  staggered per identity. Stateless — no rows stored, no database call.

## Updating config values

- `MyApp.SystemConfig.update_entry("key", %{value: "new_value"})` — updates the database and refreshes the cache across the cluster

## Testing

In test environment, a `Test` submodule is automatically generated:

- `MyApp.SystemConfig.Test.stub("key", value)` — process-scoped override, safe for `async: true` tests. For a `:variant` flag, pass the variant name to force it for every identity.
- `MyApp.SystemConfig.Test.insert_entry("key", value)` — writes to the database, use for LiveView/integration tests where the config is read in a different process

Stubs are only consulted when `cache_enabled: false`, which is the intended test
configuration.

## Targeting rules (force a value for a specific key)

Pass a context of attributes and let rules force a value for matching callers.
Rules live in the database, so adding a beta customer needs no deploy.

```elixir
# once per request -- a plug, or a LiveView on_mount hook
PhoenixFlags.put_context(user_id: user.id, company_id: user.company_id)

# then, unchanged call sites
MyApp.SystemConfig.get("enable_benefits", false)

# or explicit, which wins over the process context
MyApp.SystemConfig.get("enable_benefits", false, context: %{company_id: 999})
```

Managing rules:

- `MyApp.SystemConfig.put_target(key, conditions: [...], value: "true")`
- `MyApp.SystemConfig.targets(key)` — in evaluation order
- `MyApp.SystemConfig.delete_target(target_id)`

```elixir
MyApp.SystemConfig.put_target("enable_benefits",
  conditions: [[attribute: :company_id, operator: :in, values: [123, 456]]],
  value: "true"
)
```

Rules:

- Operators are `:in`, `:not_in`, `:eq`, `:starts_with`. Conditions in one rule
  are **ANDed**; rules are checked in order and the **first match wins**.
- Precedence on every read: test stub, then a matching rule, then the stored
  value or the `:variant` split. A rule therefore overrides an A/B split.
- **Everything compares as strings.** `%{company_id: 123}` matches `"123"`, and
  `:company_id` matches `"company_id"`. This is the usual reason a rule does not
  fire.
- A **missing attribute never matches**, `:not_in` included.
- A rule value is validated against the flag's type; a `:variant` rule must name
  a declared variant.
- **`:secret` flags cannot be targeted** — the value would be stored as plaintext.
- The context is **per-process and not inherited**. `Task.async/1` sees none of
  it; pass `context: PhoenixFlags.context()` in, or set it again inside.
- Requires the V4 migration (`PhoenixFlags.Migration.up(version: 4)`).

## Admin dashboard

Mount it with one router line, inside a pipeline that authenticates:

```elixir
scope "/admin" do
  pipe_through [:browser, :require_admin]

  flags_dashboard "/flags",
    config: MyApp.SystemConfig,
    on_mount: [{MyAppWeb.AdminAuth, :ensure_authenticated}]
end
```

- The dashboard ships **no authentication**. Guard it at both layers: a router
  pipeline for the HTTP request *and* an `:on_mount` hook for the LiveView
  connection. A pipeline alone leaves the WebSocket mount open.
- Booleans toggle in place; every other type opens an edit dialog. `:variant`
  flags get a weights editor with a running total that must reach 100.
- The dialog also lists a flag's targeting rules and can add or delete them
  (single-condition rules; multi-condition ones are created via `put_target/2`
  and render there too).
- Options: `:config` (required), `:on_mount`, `:live_socket_path`, `:app_js`.

## Database migration

Use the provided migration module:

```elixir
defmodule MyApp.Repo.Migrations.CreateSystemFlags do
  use Ecto.Migration

  def up, do: PhoenixFlags.Migration.up()
  def down, do: PhoenixFlags.Migration.down()
end
```

## Architecture notes

- Storage is in the `system_flags` PostgreSQL table (source of truth)
- Cache is a single `:persistent_term` key holding a `%{key => value}` map; a
  `:variant` flag's value is a pre-parsed `%PhoenixFlags.Variant{}`, so
  assignment is a hash and a short list walk with no parsing per read
- Cluster sync happens via direct `Node.list()` messaging — no PubSub dependency required
