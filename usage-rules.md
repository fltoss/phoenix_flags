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

## Updating config values

- `MyApp.SystemConfig.update_entry("key", %{value: "new_value"})` — updates the database and refreshes the cache across the cluster

## Testing

In test environment, a `Test` submodule is automatically generated:

- `MyApp.SystemConfig.Test.put_override("key", value)` — process-scoped override, safe for `async: true` tests
- `MyApp.SystemConfig.Test.insert_entry("key", value)` — writes to the database, use for LiveView/integration tests where the config is read in a different process

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
- Cache is a single `:persistent_term` key holding a `%{key => value}` map
- Cluster sync happens via direct `Node.list()` messaging — no PubSub dependency required
