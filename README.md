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
- **Typed values** — boolean, integer, decimal, percentage, select, string
- **Compile-time validation** — `flag/2` macro validates keys, types, and defaults at compile time
- **Declarative flags** — define flags in code, auto-seeded on startup, stale flags auto-removed
- **Cluster-aware** — writes replicate to all connected nodes automatically
- **Test-friendly** — process dictionary overrides (no DB, no races) + Ecto sandbox helpers
- **Embedded admin dashboard** — LiveView UI that renders inside your app's layout, mount with one router line
- **Versioned migrations** — Oban-style migration versioning for schema upgrades
- **Metadata sync** — label, description, category changes deploy automatically; runtime values preserved

## Installation

Add `phoenix_flags` to your dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:phoenix_flags, "~> 0.1.0"}
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
| Select | `:select` | `"ses"` | `"ses"` | app-defined |
| Secret | `:secret` | ciphertext | `"plaintext"` | none (see [Secrets](#secrets)) |

All values are stored as strings. Casting happens once when the cache is loaded,
not on every read.

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
    <<iv::16-binary-unit(8), tag::16-binary-unit(8), ct::binary>> = Base.decode64!(blob)
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
stored as a PostgreSQL comment on the `system_flags` table.

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

Visit `/admin/flags` to see all your flags grouped by category with:
- Toggle switches for booleans
- Inline edit forms for other types
- Validation errors displayed on save
- Dark mode support (via `prefers-color-scheme`)

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

- **Self-contained** — ships its own CSS and HTML layout, served via an inline asset route
- **Isolated `live_session`** — won't conflict with your app's sessions
- **Session-based config** — the router macro passes your config module through
  the LiveView session

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
| Typed values | No | Boolean only | 6 types + validation |
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

## Development

A standalone dev server is included for manual testing of the dashboard:

```bash
mix run dev.exs
```

This boots a minimal Phoenix server on http://localhost:4005 with sample flags,
audit logging enabled, and auto-opens the browser. It uses its own
`phoenix_flags_dev` database (created automatically).

## License

MIT License. See [LICENSE](LICENSE) for details.
