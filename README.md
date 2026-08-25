# PhoenixFlags

Database-backed, cached, cluster-aware system configuration for Phoenix.

PhoenixFlags gives you a **system settings page** for your Phoenix app —
typed configuration values stored in PostgreSQL, cached in `:persistent_term`
for zero-cost reads, with automatic cluster replication and compile-time
validated flag declarations.

## Why PhoenixFlags?

Most Phoenix apps eventually need runtime-configurable settings that aren't
environment variables — things like "enable the benefits integration" or
"set the default fee percentage". The usual approaches each have drawbacks:

| Approach | Problem |
|---|---|
| `Application.get_env` | Requires a deploy to change. No UI. |
| Environment variables | Same — requires restart. No validation. |
| Feature flag service (LaunchDarkly, FunWithFlags) | External dependency. Often boolean-only. Overkill for system settings. |
| Ad-hoc database table | No caching, no cluster sync, no type system, rebuilt per project. |

PhoenixFlags occupies the middle ground: typed values with validation, zero-cost
cached reads, cluster-aware writes, declarative flag definitions with compile-time
checks, and a simple API for building admin UIs. One dependency, no external services.

## Features

- **Zero-cost reads** — `:persistent_term` cache, no process calls, no ETS copies
- **Typed values** — boolean, integer, decimal, percentage, select, string, secret, variant
- **A/B testing** — weighted variants assigned by a consistent hash of an identity,
  editable at runtime for gradual rollouts
- **Targeting rules** — force a value for one user, company, or any attribute you
  pass, added from the dashboard without a deploy
- **Compile-time validation** — `flag/2` macro validates keys, types, and defaults at compile time
- **Declarative flags** — define flags in code, auto-seeded on startup, stale flags auto-removed
- **Cluster-aware** — writes notify all connected nodes immediately; a periodic
  refresh heals nodes that missed a notification (partition, restart)
- **Test-friendly** — process dictionary overrides (no DB, no races) + Ecto sandbox helpers
- **Embedded admin dashboard** — LiveView UI that renders inside your app's layout, mount with one router line
- **Versioned migrations** — Oban-style migration versioning for schema upgrades
- **Metadata sync** — label, description, category changes deploy automatically; runtime values preserved

## Installation

Add `phoenix_flags` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:phoenix_flags, "~> 0.6"}
  ]
end
```

## Quick Start

### 1. Define your flags module

```elixir
defmodule MyApp.SystemConfig do
  use PhoenixFlags,
    otp_app: :my_app,
    repo: MyApp.Repo

  flag "enable_benefits",
    type: :boolean,
    default: "false",
    category: "integrations",
    label: "Enable Benefits",
    description: "When enabled, the Benefits integration is active."

  flag "default_fee_percentage",
    type: :percentage,
    default: "5.0",
    category: "fees",
    label: "Default fee %",
    description: "Applied to all new transactions."

  flag "max_retries",
    type: :integer,
    default: "3",
    category: "system",
    label: "Max retries",
    description: "Maximum retry attempts for failed jobs."

  # Convenience helpers
  def benefits_enabled?, do: get("enable_benefits", false)
end
```

Flags are validated at compile time. A typo in the type or an invalid default
will raise `PhoenixFlags.Error` during `mix compile` — not at runtime.

### 2. Create the migration

```bash
mix ecto.gen.migration create_system_flags
```

```elixir
defmodule MyApp.Repo.Migrations.CreateSystemFlags do
  use Ecto.Migration

  def up, do: PhoenixFlags.Migration.up()
  def down, do: PhoenixFlags.Migration.down(version: 1)
end
```

That's it — one migration for the table. Flag entries are seeded automatically
on application startup from your `flag/2` declarations.

### 3. Add to your supervision tree

```elixir
# lib/my_app/application.ex
children = [
  MyApp.Repo,
  MyApp.SystemConfig,
  # ...
]
```

### 4. Configure test environment

```elixir
# config/test.exs
config :my_app, MyApp.SystemConfig, cache_enabled: false
```

### 5. Run the migration

```bash
mix ecto.migrate
```

On first boot, PhoenixFlags will seed your declared flags into the database.

## Reading Values

```elixir
MyApp.SystemConfig.get("enable_benefits")
#=> false  (cast from "false" to boolean)

MyApp.SystemConfig.get("default_fee_percentage")
#=> #Decimal<5.0>

MyApp.SystemConfig.get("nonexistent", "fallback")
#=> "fallback"

# Via convenience helper
MyApp.SystemConfig.benefits_enabled?()
#=> false
```

Reads go directly to `:persistent_term` — no GenServer call, no ETS copy,
no database query. This is as fast as reading a module attribute.

## Updating Values

```elixir
MyApp.SystemConfig.update_entry("enable_benefits", %{"value" => "true"})
#=> {:ok, %PhoenixFlags.Entry{key: "enable_benefits", value: "true", ...}}
```

An update triggers three things in sequence:

1. Database write (source of truth)
2. Local `:persistent_term` cache reload
3. `:reload` message sent to all connected cluster nodes

Invalid values are rejected with changeset errors:

```elixir
MyApp.SystemConfig.update_entry("enable_benefits", %{"value" => "maybe"})
#=> {:error, #Ecto.Changeset<errors: [value: {"must be true or false", []}]>}

MyApp.SystemConfig.update_entry("default_fee_percentage", %{"value" => "150"})
#=> {:error, #Ecto.Changeset<errors: [value: {"must be between 0 and 100", []}]>}
```

## Declarative Flags

The `flag/2` macro is the recommended way to define flags. It provides:

### Compile-Time Validation

```elixir
# This raises PhoenixFlags.Error at compile time:
flag "bad_flag", type: :invalid_type, default: "x"

# So does this:
flag "bad_bool", type: :boolean, default: "yes"  # must be "true" or "false"

# And this:
flag "bad_pct", type: :percentage, default: "150"  # must be 0-100
```

### Automatic Seeding

On GenServer startup, PhoenixFlags syncs the database with your declarations:

- **New flags** are inserted with their declared defaults
- **Removed flags** (no longer in code) are deleted from the database
- **Changed metadata** (label, description, category) is updated automatically
- **Runtime values are preserved** — if an admin changed a value via the UI, it stays
- **Type changes reset the value** — if you change a flag from `:boolean` to `:integer`, the old value `"true"` would be invalid, so it's reset to the declared default

This means you never write seed migrations. Add a flag, deploy, done.

### Supported Types

| Type | Elixir atom | Stored as | Cast to | Validation |
|---|---|---|---|---|
| String | `:string` | `"hello"` | `"hello"` | none |
| Boolean | `:boolean` | `"true"` | `true` | `"true"` or `"false"` |
| Integer | `:integer` | `"42"` | `42` | must parse as integer |
| Decimal | `:decimal` | `"3000.50"` | `Decimal.new("3000.50")` | must parse as decimal |
| Percentage | `:percentage` | `"50"` | `Decimal.new("50")` | 0..100 |
| Select | `:select` | `"ses"` | `"ses"` | must be one of the declared `:options` |
| Secret | `:secret` | ciphertext | `"plaintext"` | none (see [Secrets](#secrets)) |
| Variant | `:variant` | `"a=50,b=50"` | `%Variant{}` | weights total 100, declared (see [A/B Testing](#ab-testing)) |

All values are stored as strings. Casting happens once when the cache is loaded,
not on every read.

`:select` membership is enforced on writes as well as on the declared default,
so `get/2` can only ever return one of the declared option values. That matters
because the rendered `<select>` is not a validation boundary — LiveView event
params come from the client — and code that pattern matches on the known
options would otherwise crash on an unexpected value.

## Secrets

For credentials (API keys, webhook signing secrets, etc.) use `type: :secret`.
PhoenixFlags encrypts the value at rest using a host-supplied encryptor, masks
it in the admin dashboard, and redacts it in the audit log.

### 1. Write an encryptor module

Any module that exports `encrypt/1` and `decrypt/1` on binaries will do —
PhoenixFlags is crypto-agnostic so you pick the cipher and manage the key.
A minimal AES-256-GCM version:

```elixir
defmodule MyApp.FlagEncryptor do
  @aad "phoenix_flags_v1"

  def encrypt(plaintext) do
    iv = :crypto.strong_rand_bytes(12)
    {ct, tag} = :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, plaintext, @aad, true)
    Base.encode64(iv <> tag <> ct)
  end

  def decrypt(blob) do
    <<iv::12-binary, tag::16-binary, ct::binary>> = Base.decode64!(blob)
    :crypto.crypto_one_time_aead(:aes_256_gcm, key(), iv, ct, @aad, tag, false)
  end

  defp key, do: Application.fetch_env!(:my_app, __MODULE__)[:key]
end
```

### 2. Wire it into your config module

```elixir
defmodule MyApp.SystemConfig do
  use PhoenixFlags,
    otp_app: :my_app,
    repo: MyApp.Repo,
    encryptor: MyApp.FlagEncryptor

  flag "anthropic_api_key",
    type: :secret,
    category: "ai",
    label: "Anthropic API key"
end
```

Declaring any `:secret` flag **requires** an `:encryptor` option. Omitting it
raises a `PhoenixFlags.Error` at compile time; misconfiguring it (module missing
`encrypt/1` or `decrypt/1`) raises on boot.

### What the admin UI and audit log show

- Dashboard: "Set" / "Not set" with an Edit button. Editing renders a blank
  password input — operators type the new value, submit empty to clear it.
  The ciphertext is never sent to the DOM.
- Audit log (if enabled): `old_value` and `new_value` are stored as
  `"[redacted]"` when non-empty, and `""` when the secret is cleared. Rotations
  are still auditable (who + when) without leaking plaintext.

### Caveats

- PhoenixFlags does **no** crypto itself — your encryptor is the entire trust
  boundary. Key management, rotation, and algorithm choice are on you.
- `get/2` returns the decrypted plaintext from the `:persistent_term` cache;
  treat it with the same care as an env var.
- `all_grouped/0` returns entries with the stored ciphertext in `entry.value`
  — safe to render in bulk without special handling.

## A/B Testing

A `:variant` flag resolves to a *different* value per caller, chosen by a
consistent hash of an identity you supply. The same identity always gets the
same variant — on every node, across restarts and deploys — so a user sees a
stable experience and the results stay analysable.

```elixir
defmodule MyApp.SystemConfig do
  use PhoenixFlags, otp_app: :my_app, repo: MyApp.Repo

  flag "checkout_flow",
    type: :variant,
    category: "experiments",
    label: "Checkout flow experiment",
    variants: [
      {"Control",  "control",  90},
      {"New flow", "new_flow", 10}
    ]
end
```

```elixir
MyApp.SystemConfig.variant("checkout_flow", user.id)
#=> "control"

MyApp.SystemConfig.variant("checkout_flow", user.id)
#=> "control"   # always, for this user

MyApp.SystemConfig.get("checkout_flow")
#=> ** (PhoenixFlags.Error) "checkout_flow" is a :variant flag and has no single
#     value. Read it with variant("checkout_flow", identity) instead of get/2.
```

Weights are whole numbers that must total 100. They are stored as the flag's
value (`"control=90,new_flow=10"`) and so can be changed at runtime from the
dashboard — a rollout goes 5% → 15% → 40% → 100% with no deploy.

### Gradual rollouts are sticky

Buckets are cumulative in declaration order, so growing a variant at the expense
of the *next* one moves only the boundary between them. Going from
`control=90,new_flow=10` to `control=80,new_flow=20` moves the 80–90 band and
leaves everyone else exactly where they were — nobody already seeing `new_flow`
is moved back to `control`.

That property does **not** survive reordering the `:variants` declaration,
changing `:seed`, or a `:ttl` rollover. Any of those reshuffles the population.

### Assignment lifetime (`:ttl`)

By default an assignment is permanent. Set `:ttl` in milliseconds to re-roll each
caller once per window:

```elixir
flag "banner_copy",
  type: :variant,
  ttl: :timer.hours(24),      # nil (default) = never expires
  variants: [{"A", "a", 50}, {"B", "b", 50}]
```

Windows are offset per identity, so the population does not all flip at the same
instant. This is stateless — no rows are stored and no database call is made; the
window is simply folded into the hash.

### Independence and seeds

The flag key is part of the hash input, so two concurrent experiments do not
correlate: a user in `control` for one is not systematically in `control` for the
other. Pass `seed: "some-string"` to re-randomise everyone — useful when
restarting an experiment on the same flag.

Assignment uses SHA-256 rather than `:erlang.phash2/2`, which is not guaranteed
stable across OTP major versions; an OTP upgrade must not silently reshuffle a
running experiment.

### Tracking exposures

`variant/3` emits nothing by default, to keep the read path free. Pass
`telemetry: true` to emit `[:phoenix_flags, :variant, :assigned]`:

```elixir
:telemetry.attach("ab-exposures", [:phoenix_flags, :variant, :assigned], fn _e, _m, meta, _c ->
  MyApp.Analytics.track(meta.identity, meta.flag, meta.variant)
end, nil)

MyApp.SystemConfig.variant("checkout_flow", user.id, telemetry: true)
```

### Testing

```elixir
MyApp.SystemConfig.Test.stub("checkout_flow", "new_flow")
# every identity now resolves to "new_flow"
```

A missing identity would put every caller in the same bucket, so `variant/3`
raises on `nil` (or anything that is not a non-empty string or an integer)
rather than bucketing silently.

## Targeting

An A/B split is random by design. Targeting is the opposite: force a specific
value for a specific caller — onboard a beta customer, unblock one account, raise
a limit for one tenant. Rules live in the database and are added from the
dashboard, so none of that needs a deploy.

### 1. Provide a context

Set it once where you already have the current user:

```elixir
# lib/my_app_web/plugs/flag_context.ex
defmodule MyAppWeb.Plugs.FlagContext do
  def init(opts), do: opts

  def call(conn, _opts) do
    case conn.assigns[:current_user] do
      nil -> conn
      user ->
        PhoenixFlags.put_context(user_id: user.id, company_id: user.company_id)
        conn
    end
  end
end
```

Every read in that process is then targeted, with no change to the call sites:

```elixir
MyApp.SystemConfig.get("enable_benefits", false)
MyApp.SystemConfig.variant("checkout_flow", user.id)
```

Or pass one explicitly, which wins over the process context:

```elixir
MyApp.SystemConfig.get("enable_benefits", false, context: %{company_id: 999})
```

### 2. Add a rule

From the dashboard's edit dialog, or in code:

```elixir
MyApp.SystemConfig.put_target("enable_benefits",
  conditions: [[attribute: :company_id, operator: :in, values: [123, 456]]],
  value: "true"
)

MyApp.SystemConfig.targets("enable_benefits")
MyApp.SystemConfig.delete_target(target_id)
```

Conditions within a rule are **ANDed**; rules are checked in the order they were
added and the **first match wins**.

| Operator | Matches when |
|---|---|
| `:in` | the context value is any of `values` |
| `:not_in` | the context value is none of `values` |
| `:eq` | the context value equals the first of `values` |
| `:starts_with` | the context value starts with any of `values` |

```elixir
# ANDed conditions
put_target("enable_benefits",
  conditions: [
    [attribute: :plan, operator: :eq, values: ["enterprise"]],
    [attribute: :region, operator: :in, values: ["eu", "uk"]]
  ],
  value: "true"
)
```

### What wins

For every read, in order:

1. A test stub (`MyModule.Test.stub/2`), in the test environment
2. **A matching targeting rule**
3. The stored value, or for a `:variant` flag the weighted split

So a rule overrides an A/B split — pinning a customer to one arm is the point.

### Things worth knowing

- **Everything compares as strings.** A context of `%{company_id: 123}` matches a
  rule value of `"123"`; every flag value is stored as a string and rule values
  follow suit. Attribute keys too, so `:company_id` and `"company_id"` are the
  same attribute. If a rule never seems to fire, check this first.
- **A missing attribute never matches**, including for `:not_in` — "everyone
  except these" will not sweep in callers you know nothing about.
- **A rule value is validated against the flag's type**, so a `:boolean` rule
  must be `"true"`/`"false"` and a `:variant` rule must name a declared variant.
- **`:secret` flags cannot be targeted.** The rule value would be stored as
  plaintext, defeating the encryptor.
- **The context is per-process and is not inherited.** `Task.async/1` starts with
  an empty one; pass `context: PhoenixFlags.context()` into the task, or set it
  again inside.
- **Cost when unused is a single `:persistent_term` read.** A flag with no rules
  never even reads the context.

## Architecture

```
                    ┌─────────────────────┐
                    │   Your Application  │
                    │                     │
  get("key")  ────▶│  :persistent_term   │◀──── zero-copy reads
                    │  {values, entries}  │      (no process call)
                    └─────────┬───────────┘
                              │
              update_entry()  │  GenServer.call
                              ▼
                    ┌─────────────────────┐
                    │  PhoenixFlags.Server│
                    │                     │
                    │  1. Repo.update()   │
                    │  2. load_cache()    │
                    │  3. notify_peers()  │──────▶ Node.list()
                    └─────────┬───────────┘        send(:reload)
                              │
                              ▼
                    ┌─────────────────────┐
                    │    PostgreSQL        │
                    │  system_flags table  │
                    └─────────────────────┘
```

### Why `:persistent_term`?

- **Zero-copy**: Unlike ETS, `:persistent_term` values are shared across all
  processes without copying. A map with 100 entries costs zero per-read overhead.
- **No process bottleneck**: Reads bypass the GenServer entirely — they're a
  direct memory lookup.
- **Trade-off**: Writes trigger a global GC of `:persistent_term` values.
  This is fine for system config that changes rarely (minutes/hours), but
  would be bad for high-frequency writes.

### Cluster Replication

After a write, the GenServer sends `:reload` directly to its named counterpart
on all connected nodes via `send({instance_name, node}, :reload)`. No PubSub
dependency, no Phoenix channels — just Erlang distribution.

A node that misses a notification (network partition, restart in progress, full
send buffer) is not stale forever: every instance also reloads its cache from
the database on a jittered interval (`refresh_interval`, default 60 seconds).
That interval is the upper bound on cross-node staleness. Set
`refresh_interval: false` to disable the periodic refresh, or lower it if you
need tighter convergence.

### One Config Module per Repo

All flags live in a single `system_flags` table, and each config module removes
keys it doesn't declare at startup. Two config modules with different flag
declarations sharing one repo would therefore delete each other's rows — the
server detects this at boot and refuses to start. Run one PhoenixFlags module
per repo (multiple *nodes* running the same module is, of course, fine).

## Testing

In the `:test` environment, `use PhoenixFlags` generates a `Test` submodule
with two helpers:

```elixir
# Auto-generated: MyApp.SystemConfig.Test
MyApp.SystemConfig.Test.stub("key", value)   # process dictionary
MyApp.SystemConfig.Test.insert_entry("key", value)    # database
```

### Unit Tests (Same Process)

Use `stub/2` for tests where the config is read in the same process.
No database, no race conditions, safe for `async: true`:

```elixir
test "grants access when benefits enabled" do
  MyApp.SystemConfig.Test.stub("enable_benefits", true)

  assert MyApp.SystemConfig.benefits_enabled?()
  assert MyApp.Access.can_view_benefits?(user)
end

test "denies access when benefits disabled" do
  # No override needed — default is false
  refute MyApp.SystemConfig.benefits_enabled?()
end
```

### LiveView / Integration Tests (Cross-Process)

Use `insert_entry/3` when the config is read in a different process (LiveView,
channel, async task). The Ecto sandbox in shared mode makes the row visible
to all processes in the test:

```elixir
test "shows benefits section when enabled", %{conn: conn} do
  MyApp.SystemConfig.Test.insert_entry("enable_benefits", true)

  {:ok, view, _html} = live(conn, ~p"/dashboard")
  assert has_element?(view, "#benefits-section")
end
```

### Why Two Helpers?

| Helper | Mechanism | Visible to | Use when |
|---|---|---|---|
| `stub/2` | Process dictionary | Same process only | Unit tests, context tests |
| `insert_entry/3` | Database (Ecto sandbox) | All processes in test | LiveView, integration tests |

`stub/2` is faster and simpler. Use `insert_entry/3` only when you need
cross-process visibility.

## Versioned Migrations

PhoenixFlags uses Oban's migration versioning pattern. The schema version is
stored in the `system_flags_meta` table (schema V3+; older versions stored it
as a PostgreSQL comment on the `system_flags` table, and
`migrated_version/1` still reads the comment on databases that haven't run
the V3 migration yet).

When upgrading to a new package version with schema changes, generate a new
migration:

```elixir
defmodule MyApp.Repo.Migrations.UpgradeSystemFlagsToV2 do
  use Ecto.Migration

  def up, do: PhoenixFlags.Migration.up(version: 2)
  def down, do: PhoenixFlags.Migration.down(version: 2)
end
```

Check the current version:

```elixir
PhoenixFlags.Migration.migrated_version()
#=> 1
```

## Admin Dashboard

PhoenixFlags ships a self-contained LiveView dashboard with its own CSS and
layout. Mount it with a single router line — no dependency on your app's
stylesheets or layout system.

### Mounting the Dashboard

```elixir
defmodule MyAppWeb.Router do
  use Phoenix.Router
  import PhoenixFlags.Router

  scope "/admin" do
    pipe_through [:browser, :require_admin]

    flags_dashboard "/flags",
      config: MyApp.SystemConfig,
      on_mount: [{MyAppWeb.AdminAuth, :ensure_authenticated}]
  end
end
```

> **The dashboard has no built-in authentication.** It renders and edits every
> flag for anyone who can reach the route — including `:secret` values, which are
> write-only in the UI but whose changes are still actor-attributed in the audit
> log. Protect it yourself, at both layers: a router pipeline for the initial HTTP
> request (`pipe_through`) *and* an `:on_mount` hook for the LiveView connection.
> A pipeline alone does not guard the WebSocket mount.

Visit `/admin/flags` to see all your flags grouped by category with:
- Toggle switches for booleans, which save on click
- An **Edit dialog** for every other type, opened from the row
- Percentage bars for `:variant` flags, with a weights editor and a live total
- `Set` / `Not set` for `:secret` flags, edited through a blank password field
- Validation errors shown in the dialog, which stays open until the value is valid
- Dark mode support (via `prefers-color-scheme`)

The dialog closes on **Save**, **Cancel**, the **×**, **Escape**, or a click on
the backdrop. Keyboard focus moves into the dialog when it opens.

### Dashboard Options

```elixir
flags_dashboard "/flags",
  config: MyApp.SystemConfig,                              # required
  on_mount: [{MyAppWeb.AdminAuth, :ensure_authenticated}]  # auth hooks
```

| Option | Description |
|---|---|
| `:config` (required) | The module that `use PhoenixFlags` |
| `:on_mount` | List of `on_mount` hooks for the live session (e.g. authentication) |
| `:live_socket_path` | Defaults to `"/live"` |
| `:app_js` | Path to the app's JS bundle. Defaults to `"/assets/js/app.js"` |

### How It Works

- **Self-contained** — ships its own CSS and HTML layout, served via an inline
  asset route with a content-hashed, immutable URL
- **Isolated `live_session`** — won't conflict with your app's sessions
- **Session-based config** — the router macro passes your config module through
  the LiveView session
- **One dialog at a time** — the editor is rendered once for whichever flag is
  being edited, derived from the current entries rather than held in its own
  assign, so a cluster update can't leave it showing a stale value
- **No client-side trust** — event payloads are re-validated server-side. A
  `:variant` save is rebuilt from the *declared* variants in declaration order,
  so a forged field cannot introduce a variant name or reorder the buckets

### Custom UI

If you want full control, build your own LiveView using the data API:

```elixir
MyApp.SystemConfig.all_grouped()
#=> [{"integrations", [%Entry{key: "enable_benefits", ...}]}, ...]

MyApp.SystemConfig.update_entry("enable_benefits", %{"value" => "true"})
#=> {:ok, %Entry{...}}
```

## Audit Log

PhoenixFlags includes an opt-in audit log that records every flag value change.

### Setup

Enable audit logging in your config module:

```elixir
defmodule MyApp.SystemConfig do
  use PhoenixFlags,
    otp_app: :my_app,
    repo: MyApp.Repo,
    audit: true,
    actor_fn: &MyApp.SystemConfig.current_user/1

  # Extract the actor from the LiveView socket or Plug conn
  def current_user(%Phoenix.LiveView.Socket{} = socket) do
    socket.assigns.current_admin.email
  end

  def current_user(_), do: "system"

  # ... flag declarations
end
```

Then generate a migration to add the audit table:

```elixir
defmodule MyApp.Repo.Migrations.UpgradeSystemFlagsV2 do
  use Ecto.Migration

  def up, do: PhoenixFlags.Migration.up(version: 2)
  def down, do: PhoenixFlags.Migration.down(version: 2)
end
```

### How It Works

- **`actor_fn`** is called with the LiveView socket during mount. The returned string is stored as the actor in the audit log.
- Every successful `update_entry` inserts a row into `system_flags_audit` with the key, old value, new value, actor, and timestamp.
- When `audit: false` (the default), zero additional code runs — no overhead.
- Audit insert failures are logged but never block the update.

### Querying the Audit Log

```elixir
MyApp.SystemConfig.audit_log()
#=> [%PhoenixFlags.AuditLog{key: "enable_benefits", old_value: "false", new_value: "true", actor: "admin@example.com", ...}, ...]

MyApp.SystemConfig.audit_log("enable_benefits")
#=> [%PhoenixFlags.AuditLog{...}, ...]  # filtered by key
```

### Passing Actor from Code

When updating flags outside the dashboard, pass the actor via opts:

```elixir
MyApp.SystemConfig.update_entry("enable_benefits", %{"value" => "true"},
  actor: "deploy@ci"
)
```

## Comparison

| | Application env | FunWithFlags | PhoenixFlags |
|---|---|---|---|
| Runtime changes | No (deploy required) | Yes | Yes |
| Typed values | No | Boolean only | 8 types + validation |
| A/B testing | No | No | Weighted variants, consistent hash |
| Per-user targeting | No | Actor gates (code) | Runtime rules on any attribute |
| Caching | N/A (in-memory) | ETS | `:persistent_term` (zero-copy) |
| Cluster sync | No | Redis/Ecto polling | Direct node messaging |
| Admin UI | N/A | No | Built-in dashboard, one router line |
| External deps | None | Redis (optional) | None |
| Compile-time checks | No | No | Yes (`flag/2` macro) |
| Auto-seeding | No | No | Yes (on startup) |

## API Reference

### Module API (generated by `use PhoenixFlags`)

| Function | Description |
|---|---|
| `get(key, default \\ nil)` | Read a cached value, cast to native type |
| `update_entry(key, attrs, opts \\ [])` | Update a value, sync cache + cluster. Accepts `:timeout` and `:actor`. |
| `all_grouped()` | All entries grouped by category (for admin UI) |
| `flags()` | List of declared `PhoenixFlags.Flag` structs |
| `select_options(key)` | `{label, value}` options for a `:select` flag, or `[]` |
| `variant(key, identity, opts \\ [])` | Variant assigned to `identity`. Accepts `:default`, `:telemetry`. |
| `variants(key)` | Declared `{label, value, weight}` variants for a `:variant` flag, or `[]` |
| `targets(key)` | Targeting rules for a flag, in evaluation order |
| `put_target(key, attrs)` | Add a targeting rule (`:conditions`, `:value`, optional `:position`) |
| `delete_target(id)` | Delete a targeting rule |
| `audit_log()` | All audit entries, newest first (requires `audit: true`) |
| `audit_log(key)` | Audit entries for a specific key, newest first |

### Test API (generated in `:test` env as `MyModule.Test`)

| Function | Description |
|---|---|
| `stub(key, value)` | Process-scoped override, no DB |
| `insert_entry(key, value, opts)` | DB insert/upsert for cross-process tests |

### Router API

| Macro | Description |
|---|---|
| `flags_dashboard(path, opts)` | Mount the embedded dashboard LiveView |

### Migration API

| Function | Description |
|---|---|
| `PhoenixFlags.Migration.up(opts)` | Run migrations up to version |
| `PhoenixFlags.Migration.down(opts)` | Roll back migrations to version |
| `PhoenixFlags.Migration.migrated_version()` | Current schema version |

### Context API

| Function | Description |
|---|---|
| `PhoenixFlags.put_context(attrs)` | Replace the current process's targeting context |
| `PhoenixFlags.merge_context(attrs)` | Merge into it |
| `PhoenixFlags.context()` | Read it |
| `PhoenixFlags.clear_context()` | Clear it |

## Development

Everything below needs a reachable PostgreSQL. Override the connection with the
`POSTGRES_USER`, `POSTGRES_PASSWORD` and `DB_HOST` environment variables.

### Running the dashboard locally

```bash
mix run dev.exs
```

This boots a real Phoenix + LiveView server on http://localhost:4005, opens your
browser, and seeds a sample flag of every type — including two `:variant`
experiments, so you can exercise the weights editor. It uses its own
`phoenix_flags_dev` database, created automatically, and builds its JavaScript
inline from the `phoenix` and `phoenix_live_view` dependencies, so there is no
asset pipeline to set up.

Restart the server after changing code. Editing `priv/static/app.css` is picked
up on restart too — the dashboard's asset module declares the stylesheet as an
`@external_resource`, so changing it triggers recompilation.

### Running the tests

`mix test` creates and migrates `phoenix_flags_test` itself.

```bash
mix test                                          # everything
mix test test/phoenix_flags/variant_test.exs      # A/B assignment properties
mix test test/phoenix_flags/ui                    # the LiveView dashboard
```

The dashboard is covered by `Phoenix.LiveViewTest`, so its behaviour — opening
the dialog, saving, validation errors, forged payloads — is tested without a
browser.

To match CI exactly:

```bash
mix format --check-formatted
mix deps.unlock --check-unused
mix compile --warnings-as-errors
mix credo
mix hex.audit
MIX_ENV=dev mix docs
```

CI also runs the suite on Elixir 1.16/OTP 26, 1.18/OTP 27 and 1.20/OTP 28, which
is what verifies the declared `elixir: "~> 1.16"` floor.

### Poking at the API interactively

`dev.exs` ends in `Process.sleep(:infinity)`, so `iex -S mix run dev.exs` never
reaches a prompt. Use a throwaway script instead:

```elixir
# probe.exs  →  mix run probe.exs
Code.require_file("bench/bench_helper.exs")
alias PhoenixFlags.{Config, Server}

defmodule Probe do
  use PhoenixFlags, otp_app: :phoenix_flags, repo: PhoenixFlags.TestRepo

  flag "exp",
    type: :variant,
    category: "e",
    label: "Exp",
    variants: [{"Control", "control", 90}, {"New", "new", 10}]
end

{:ok, _} =
  Server.start_link(%Config{
    otp_app: :phoenix_flags,
    repo: PhoenixFlags.TestRepo,
    name: Probe,
    cache_enabled: true
  })

IO.inspect(for index <- 1..10, do: Probe.variant("exp", "user-#{index}"))
Probe.update_entry("exp", %{"value" => "control=20,new=80"})
IO.inspect(for index <- 1..10, do: Probe.variant("exp", "user-#{index}"))
```

> `bench/bench_helper.exs` points at its own `phoenix_flags_bench` database,
> created and migrated on first use. Scripts that require it therefore cannot
> disturb `phoenix_flags_test` — which matters because they run outside the Ecto
> sandbox, so their writes commit.

### Trying it in your own app

Point at a local checkout instead of Hex:

```elixir
{:phoenix_flags, path: "../phoenix_flags"}
```

Then `mix deps.get`, generate the migration, and mount the dashboard as above.

### Benchmarks

```bash
mix run bench/phoenix_flags_bench.exs
```

See [docs/benchmarks.md](docs/benchmarks.md) for recorded results.

## License

MIT License. See [LICENSE](LICENSE) for details.
