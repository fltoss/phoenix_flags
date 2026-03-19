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

All values are stored as strings. Casting happens once when the cache is loaded,
not on every read.

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
MyApp.SystemConfig.Test.put_override("key", value)   # process dictionary
MyApp.SystemConfig.Test.insert_entry("key", value)    # database
```

### Unit Tests (Same Process)

Use `put_override/2` for tests where the config is read in the same process.
No database, no race conditions, safe for `async: true`:

```elixir
test "grants access when benefits enabled" do
  MyApp.SystemConfig.Test.put_override("enable_benefits", true)

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
| `put_override/2` | Process dictionary | Same process only | Unit tests, context tests |
| `insert_entry/3` | Database (Ecto sandbox) | All processes in test | LiveView, integration tests |

`put_override/2` is faster and simpler. Use `insert_entry/3` only when you need
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

PhoenixFlags ships a LiveView dashboard that renders inside your app's existing
layout. Mount it with a single router line.

### Mounting the Dashboard

```elixir
defmodule MyAppWeb.Router do
  use Phoenix.Router
  import PhoenixFlags.Router

  scope "/admin" do
    pipe_through [:browser, :require_admin]

    flags_dashboard "/flags",
      config: MyApp.SystemConfig,
      layout: {MyAppWeb.Layouts, :app}
  end
end
```

Visit `/admin/flags` to see all your flags grouped by category with:
- Toggle switches for booleans
- Inline edit forms for other types
- Validation errors displayed on save

### Dashboard Options

```elixir
flags_dashboard "/flags",
  config: MyApp.SystemConfig,                              # required
  layout: {MyAppWeb.Layouts, :app},                        # your app layout
  on_mount: [{MyAppWeb.AdminAuth, :ensure_authenticated}]  # auth hooks
```

| Option | Description |
|---|---|
| `:config` (required) | The module that `use PhoenixFlags` |
| `:layout` | Layout to wrap the dashboard (e.g. `{MyAppWeb.Layouts, :app}`) |
| `:on_mount` | List of `on_mount` hooks for the live session (e.g. authentication) |
| `:live_socket_path` | Defaults to `"/live"` |

### How It Works

- **Isolated `live_session`** — won't conflict with your app's sessions
- **Uses your app's layout** — renders inside your existing navigation/sidebar
  via the `:layout` option
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
| `update_entry(key, attrs, opts \\ [])` | Update a value, sync cache + cluster. Accepts `:timeout`. |
| `all_grouped()` | All entries grouped by category (for admin UI) |
| `flags()` | List of declared `PhoenixFlags.Flag` structs |

### Test API (generated in `:test` env as `MyModule.Test`)

| Function | Description |
|---|---|
| `put_override(key, value)` | Process-scoped override, no DB |
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

## License

MIT License. See [LICENSE](LICENSE) for details.
