# PhoenixFlags

Database-backed, cached, cluster-aware system configuration for Phoenix applications.

PhoenixFlags gives you a **system settings page** pattern: typed configuration
values stored in PostgreSQL, cached in `:persistent_term` for zero-cost reads,
with automatic cluster replication. Think of it as the middle ground between
`Application.get_env` (no runtime changes) and a full feature flag service
(overkill for most settings).

## Features

- **Zero-cost reads** — values cached in `:persistent_term`, no process calls or ETS copies
- **Typed values** — boolean, integer, decimal, percentage, select, and string types
- **Cluster-aware** — writes automatically replicate to all connected nodes
- **Test-friendly** — process dictionary overrides for unit tests, Ecto sandbox for integration tests
- **Versioned migrations** — Oban-style migration system with version tracking
- **Simple API** — `get/2`, `update_entry/2`, `all_grouped/0`

## Installation

Add `phoenix_flags` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:phoenix_flags, "~> 0.1.0"}
  ]
end
```

## Setup

### 1. Define your configuration module

Create a module that uses `PhoenixFlags`:

```elixir
defmodule MyApp.SystemConfig do
  use PhoenixFlags,
    otp_app: :my_app,
    repo: MyApp.Repo

  # App-specific convenience helpers
  def benefits_enabled?, do: get("enable_benefits", false)
  def maintenance_mode?, do: get("maintenance_mode", false)
end
```

### 2. Create the migration

```bash
mix ecto.gen.migration add_system_flags
```

```elixir
defmodule MyApp.Repo.Migrations.AddSystemFlags do
  use Ecto.Migration

  def up, do: PhoenixFlags.Migration.up()
  def down, do: PhoenixFlags.Migration.down(version: 1)
end
```

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

## Usage

### Reading values

```elixir
# With default
MyApp.SystemConfig.get("enable_benefits", false)
#=> false

# Without default (returns nil if not found)
MyApp.SystemConfig.get("max_retries")
#=> 5

# Via app-specific helper
MyApp.SystemConfig.benefits_enabled?()
#=> true
```

### Updating values

```elixir
MyApp.SystemConfig.update_entry("enable_benefits", %{"value" => "true"})
#=> {:ok, %PhoenixFlags.Entry{key: "enable_benefits", value: "true", ...}}

MyApp.SystemConfig.update_entry("enable_benefits", %{"value" => "invalid"})
#=> {:error, #Ecto.Changeset<errors: [value: {"must be true or false", []}]>}
```

Updates automatically:
1. Write to the database
2. Reload the local `:persistent_term` cache
3. Notify all connected nodes to reload their caches

### Listing all values (for admin UI)

```elixir
MyApp.SystemConfig.all_grouped()
#=> [
#     {"integrations", [%Entry{key: "enable_benefits", ...}]},
#     {"email", [%Entry{key: "email_provider", ...}]}
#   ]
```

### Seeding config entries

Add entries via migrations so they're version-controlled:

```elixir
defmodule MyApp.Repo.Migrations.AddBenefitsFlag do
  use Ecto.Migration

  def change do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    execute """
    INSERT INTO system_flags (id, key, value, type, category, label, description, inserted_at, updated_at)
    VALUES (gen_random_uuid(), 'enable_benefits', 'false', 'boolean', 'integrations', 'Enable Benefits',
            'When enabled, the Benefits integration is active.', '#{now}', '#{now}')
    """
  end
end
```

## Value Types

All values are stored as strings in the database. Casting happens once when the
cache is loaded, not on every read.

| Type         | Stored as       | Cast to              | Validation                    |
|--------------|-----------------|----------------------|-------------------------------|
| `string`     | `"hello"`       | `"hello"`            | none                          |
| `boolean`    | `"true"`        | `true`               | must be `"true"` or `"false"` |
| `integer`    | `"42"`          | `42`                 | must parse as integer         |
| `decimal`    | `"3000"`        | `Decimal.new("3000")`| must parse as decimal         |
| `percentage` | `"50"`          | `Decimal.new("50")`  | 0..100                        |
| `select`     | `"ses"`         | `"ses"`              | app-defined allowed values    |

## Architecture

```
Write path:  GenServer.call -> Repo.update -> load_cache() -> notify_peers()
Read path:   :persistent_term.get -> Map.get  (zero-copy, no process call)
Test path:   Process.get -> fallback_read(Repo)  (sandbox-compatible)
```

### Cache

A single `:persistent_term` key holds a `%{key => cast_value}` map per instance.
Reads are zero-cost — `:persistent_term` shares data across all processes without
copying, unlike ETS which copies on read.

### Cluster Replication

After a write, the GenServer sends `:reload` directly to its counterpart on all
connected nodes via `send({instance_name, node}, :reload)`. No PubSub dependency
is required.

### Multiple Instances

Each `use PhoenixFlags` module creates an independent instance with its own
cache and GenServer. While most apps need only one, the architecture supports
multiple instances out of the box.

## Testing

When you `use PhoenixFlags` in test environment, a `Test` submodule is
automatically generated with test helpers:

```elixir
# MyApp.SystemConfig.Test is auto-generated in :test env
MyApp.SystemConfig.Test.put_override("enable_benefits", true)
MyApp.SystemConfig.Test.insert_entry("enable_benefits", true)
```

### Unit tests (same process)

Use `put_override/2` — stores in the process dictionary, no DB writes, no race conditions:

```elixir
defmodule MyApp.SomeTest do
  use MyApp.DataCase

  test "does something when benefits enabled" do
    MyApp.SystemConfig.Test.put_override("enable_benefits", true)

    assert MyApp.SystemConfig.benefits_enabled?()
    # ... test your feature
  end
end
```

Process overrides are scoped to the calling process and automatically cleaned
up when the process exits. Safe for `async: true` tests.

### Integration / LiveView tests (cross-process)

Use `insert_entry/3` for LiveView tests where the config is read in a different
process. The Ecto sandbox in shared mode handles isolation:

```elixir
defmodule MyAppWeb.SomeLiveTest do
  use MyAppWeb.ConnCase

  test "shows benefits UI when enabled", %{conn: conn} do
    # DB row is visible to the LiveView process via the shared sandbox
    MyApp.SystemConfig.Test.insert_entry("enable_benefits", true)

    {:ok, view, _html} = live(conn, ~p"/some-page")
    assert has_element?(view, "#benefits-section")
  end
end
```

## Versioned Migrations

PhoenixFlags uses the same migration versioning pattern as Oban. The
current schema version is stored as a PostgreSQL comment on the `system_flags`
table.

When upgrading to a new package version with schema changes:

```elixir
defmodule MyApp.Repo.Migrations.UpgradeSystemFlagsToV2 do
  use Ecto.Migration

  def up, do: PhoenixFlags.Migration.up(version: 2)
  def down, do: PhoenixFlags.Migration.down(version: 2)
end
```

Check the current migrated version:

```elixir
PhoenixFlags.Migration.migrated_version()
#=> 1
```

## Building an Admin UI

The package provides `all_grouped/0` and `update_entry/2` — everything you need
to build an admin settings page. Here's a minimal LiveView example:

```elixir
defmodule MyAppWeb.SystemConfigLive do
  use MyAppWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok, assign(socket, grouped: MyApp.SystemConfig.all_grouped())}
  end

  def handle_event("toggle", %{"key" => key}, socket) do
    current = MyApp.SystemConfig.get(key)
    new_value = if current, do: "false", else: "true"

    case MyApp.SystemConfig.update_entry(key, %{"value" => new_value}) do
      {:ok, _} ->
        {:noreply, assign(socket, grouped: MyApp.SystemConfig.all_grouped())}
      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update")}
    end
  end

  def render(assigns) do
    ~H"""
    <div :for={{category, entries} <- @grouped}>
      <h2>{category}</h2>
      <div :for={entry <- entries}>
        <span>{entry.label}</span>
        <button :if={entry.type == "boolean"} phx-click="toggle" phx-value-key={entry.key}>
          {if entry.value == "true", do: "Enabled", else: "Disabled"}
        </button>
      </div>
    </div>
    """
  end
end
```

## License

MIT License. See [LICENSE](LICENSE) for details.
