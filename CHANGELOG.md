# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.6.2] - 2026-08-25

### Fixed

- **`:select` values are validated against their declared options on write.**
  `PhoenixFlags.Type.validate_value/2` fell through to its catch-all `:ok`
  clause for `select`, so `update_entry/3` accepted, stored and cached any
  string at all:

  ```elixir
  update_entry("feature_tier", %{"value" => "not-an-option"})
  #=> {:ok, %Entry{value: "not-an-option"}}   # before
  #=> {:error, #Ecto.Changeset<errors: [value: {"must be one of: basic, pro", []}]>}
  ```

  The constraint was already enforced on the declared default at compile time
  (`PhoenixFlags.Flag`), so this closes an inconsistency rather than adding a
  new rule. It matters because the dashboard's rendered `<select>` is not a
  validation boundary — LiveView event params are client-controlled — and an
  out-of-range value reached `get/2`, crashing consumers that pattern match on
  the known options.

  `PhoenixFlags.Entry.changeset/2` gained an optional third argument carrying
  `:select_options`; the membership check only runs when they are supplied, so
  callers that build a bare form (or a `:name` module exporting only `flags/0`)
  are unaffected.

### Upgrading

No migration or code change required. If you were relying on storing arbitrary
values in a `:select` flag, those writes now return `{:error, changeset}` —
either add the value to the flag's `:options` or change the flag to `:string`.
Values already in the database are left alone; only new writes are checked.

## [0.6.1] - 2026-08-25

### Changed

- **Dependencies updated.** No library code changes; `mix.exs` constraints are unchanged (every bump is within the existing requirements).

  | Package | From | To |
  |---|---|---|
  | `phoenix` | 1.8.9 | 1.8.12 |
  | `phoenix_live_view` | 1.2.8 | 1.2.10 |
  | `postgrex` | 0.22.3 | 0.22.4 |
  | `ecto` | 3.14.1 | 3.14.2 |
  | `req` (dev, via `igniter`) | 0.7.1 | 0.7.3 |
  | `spitfire` (dev, via `igniter`) | 0.3.13 | 0.4.0 |

### Security

- Picks up **postgrex 0.22.4**, which escapes comments in `Postgrex.stream/4` ([CVE-2026-66838](https://github.com/elixir-ecto/postgrex/blob/master/CHANGELOG.md)). PhoenixFlags does not call `Postgrex.stream/4` itself, so this is a transitive hardening for host applications that do.
- Picks up **phoenix_live_view 1.2.9**, which fixes an open redirect in `redirect/2` via ASCII tab, LF and CR ([CVE-2026-64941](https://github.com/phoenixframework/phoenix_live_view/security/advisories/GHSA-36m4-rm57-3prf)). The embedded dashboard performs no redirects or navigation of its own, so it was not exposed, but host applications on 1.2.8 should upgrade.
- `mix hex.audit` reports no retired or advisory packages.

## [0.6.0] - 2026-07-30

### Upgrading

Generate the V3 migration with `mix igniter.upgrade phoenix_flags`, or manually:

```elixir
defmodule MyApp.Repo.Migrations.UpgradeSystemFlagsV3 do
  use Ecto.Migration

  def up, do: PhoenixFlags.Migration.up(version: 3)
  def down, do: PhoenixFlags.Migration.down(version: 3)
end
```

The upgrade is seamless:

- **Existing databases** (V1 or V2): the migration widens the value columns and moves the schema version from the `system_flags` table comment into the new `system_flags_meta` table. The version is read from the comment during the transition, so no manual steps are needed.
- **Fresh databases** (new dev machines, CI): your existing migration folder keeps working — the original install migration now builds V3 directly, and older pinned migrations (`up(version: 2)`) become no-ops.
- **No downtime**: `varchar(255)` → `text` is binary-coercible in PostgreSQL, so the column change is a catalog-only update with no table rewrite, even on large audit tables.
- **Rollback**: `mix ecto.rollback` of the V3 migration restores the previous scheme exactly (columns narrowed back — this fails if any stored value now exceeds 255 characters — and the version written back to the table comment).
- **Caveat**: if you ever need to downgrade the package below 0.6.0, roll back the V3 migration *first* (while 0.6.0 is still installed). Older releases only know the comment-based version store, which V3 clears.

### Fixed

- **Full rollback works again.** `PhoenixFlags.Migration.down(version: 1)` executed invalid SQL (`COMMENT ON TABLE IF EXISTS` does not exist in PostgreSQL) after dropping the table, so `mix ecto.rollback` always failed. The redundant comment reset was removed.
- **`:secret` defaults are encrypted at seed time.** Previously a `:secret` flag with a non-empty default was written to the database in plaintext, and cached reads then failed to decrypt it. Seeding (and the value reset on type changes) now runs the default through the configured encryptor.
- **Uncached reads decrypt secrets.** With `cache_enabled: false`, `get/2` returned the stored ciphertext for `:secret` flags instead of the plaintext the cached path returns. Both paths now share the same decrypt-and-cast pipeline.
- **Server survives database errors during writes.** A `Postgrex.Error` raised inside `update_entry/3` (e.g. connection loss) crashed the GenServer; it is now rescued and returned as an error changeset.
- **Restarts no longer serve call-site defaults.** `terminate/2` erased the persistent_term config key that `get/3` needs, so every flag read as its default during a Server restart. The cache, config, and order keys are now all left intact and overwritten by `init/1`.
- **Decrypt failures signalled by return value are handled.** An encryptor returning a non-binary (e.g. `:error` from `:crypto.crypto_one_time_aead/7`) was cached as if it were the plaintext; it now logs a warning and yields `nil`.
- **README example encryptor could not decrypt its own output** (12-byte IV written, 16-byte IV read). The install snippet also referenced version `0.1.0` and omitted the `organization` option.
- **Dashboard toggle only accepts boolean flags.** A forged `pf-toggle` event could overwrite any flag (including strings/selects) with `"true"`/`"false"`.
- **Mounting `flags_dashboard` twice works.** The router macro defined a shared pipeline and plug function per mount, so a second dashboard silently reused the first mount's `:app_js` and emitted duplicate-clause warnings.
- **Deterministic audit ordering.** Audit queries now tiebreak on `id` — `inserted_at` has second precision, so same-second changes had nondeterministic order.

### Added

- **Migration V03** widens `system_flags.value` and the audit `old_value`/`new_value` columns from `varchar(255)` to `text` (encrypted secrets routinely exceed 255 characters and previously crashed the Server on write), and moves the schema version out of the `system_flags` table comment into a queryable `system_flags_meta` table. Older databases are still detected via the comment fallback, and rolling back V03 restores the comment. `mix igniter.upgrade phoenix_flags` generates the migration.
- **Periodic cache refresh.** Each instance reloads its cache from the database on a jittered `refresh_interval` (default 60s, `false` to disable), bounding staleness for nodes that miss a `:reload` notification during partitions or restarts.
- **One-config-module-per-repo guard.** Two config modules with different flag declarations sharing one repo would delete each other's rows at seed time; the Server now detects this at boot and raises with a clear message.

### Changed

- `PhoenixFlags.Config.new!/1` raises on unknown options instead of silently ignoring them (a typo like `audit_enabled:` left auditing off).
- `audit_log/0` and `audit_log/1` raise a clear `PhoenixFlags.Error` when `audit: true` is not set, instead of failing with a database error about the missing table.
- `:jason` is now an optional dependency — nothing in `lib/` uses it, so consumers are no longer forced to install it.
- `usage-rules.md` is now included in the published package.

## [0.5.0] - 2026-04-23

### Added

- **Audit log.** Opt-in per-flag change history via `audit: true` on `use PhoenixFlags`. Writes to a new `system_flags_audit` table. `actor_fn` resolves the actor from the LiveView socket / Plug conn. `audit_log/0` and `audit_log/1` query the history.
- **Migration V02** adds the `system_flags_audit` table. `PhoenixFlags.Migration.up(version: 2)` runs the whole chain for new installs; existing installs add a second migration calling the same helper (the `mix igniter.upgrade phoenix_flags` task generates this automatically).
- **`:secret` flag type** for credentials and other sensitive values. Secrets are encrypted at rest via a host-supplied encryptor module (`encrypt/1` + `decrypt/1`), displayed in the dashboard as "Set" / "Not set" with a password-style edit input, and redacted as `"[redacted]"` in the audit log. PhoenixFlags ships no cryptography itself — you pick the cipher and manage the key.
- **`:encryptor` option** on `use PhoenixFlags`. Required whenever any `:secret` flag is declared — omitting it raises a `PhoenixFlags.Error` at compile time with the list of offending keys. A boot-time check also verifies the encryptor module exports `encrypt/1` and `decrypt/1`.
- **`mix igniter.upgrade phoenix_flags`** now works — new `Mix.Tasks.PhoenixFlags.Upgrade` module. Generates the v2 migration for users upgrading from 0.4.x.

### Changed

- `update_entry/3` accepts an `:actor` option that's recorded in the audit log.
- `Entry.changeset/2` accepts `""` as a valid value for `:secret` flags (so operators can clear a secret); non-secret flags continue to reject empty strings as before.
- **Renamed `PhoenixFlags.Testing.put_override/3` → `stub/3` and `get_override/2` → `get_stub/2`.** The generated `MyApp.SystemConfig.Test.stub/2` helper exposes the new name. This is a breaking API change for tests written against 0.4.x — rename `.Test.put_override("key", value)` to `.Test.stub("key", value)`.

## [0.4.2] - 2026-03-20

### Changed

- `update_entry/3` now patches the persistent_term cache in-memory instead of doing a full `repo.all(Entry)` reload — reduces DB calls per write from 3 to 2
- Flag declaration order index is now pre-computed once at startup and stored in persistent_term, instead of being rebuilt on every `all_grouped/0` call

### Added

- Benchee benchmarks (`bench/phoenix_flags_bench.exs`) covering all public functions
- Benchmark documentation (`docs/benchmarks.md`) with I/O profiles and results

## [0.4.1] - 2026-03-20

### Fixed

- SQL injection vector in migration `prefix` — now validated against `^[a-z_][a-z0-9_]*$`
- Unsafe `String.to_integer/1` in `migrated_version/1` — replaced with `Integer.parse/1` with fallback
- Cast failures (`cast_value/2`) now log at `:warning` instead of `:debug` for better observability
- Cache reload failures now log at `:error` instead of `:warning`
- `insert_all` seed log now reports the actual inserted count, not the declared count
- `terminate/2` now logs cleanup failures at `:debug` instead of silently swallowing them
- `to_seed_map/1` catch-all clause tightened to require `:key`, `:type`, and `:value` keys
- Moved `require Logger` to top of `Entry` module

### Added

- Tests for malformed DB values (corrupted integer, decimal, percentage, partial integer)
- `docs/TODO.md` with planned improvements

## [0.4.0] - 2026-03-20

### Added

- Self-contained CSS and HTML layout — dashboard no longer depends on host app's stylesheets or layout system
- Asset plug serves CSS with content-hashed URLs and immutable cache headers
- Own root layout with `<script>` tag to load the host app's LiveView JS
- `:app_js` option on `flags_dashboard` to customise the JS bundle path (defaults to `/assets/js/app.js`)
- 14 LiveView tests covering renders, toggle, edit, save, validation errors, cancel, and select
- `select_options/1` callback on the generated module for `:select` type flag options
- Declaration-order sorting — categories and entries always render in `flag/2` declaration order

### Changed

- Dashboard is fully self-contained (like Oban Web / LiveDashboard) — no `@source` directive or `:layout` option needed
- Removed `:layout` option from `flags_dashboard` macro
- Removed flash messages from dashboard — updates are instant and don't need confirmation
- Extracted `entry_info` component to reduce template duplication
- Consolidated integer/decimal/percentage inputs into a single component clause
- Extracted `input_class` and `reload` helpers to reduce repetition

### Removed

- `:layout` option from `flags_dashboard` — the package owns its own layout now
- Flash message rendering from the live layout

## [0.3.0] - 2026-03-19

### Added

- `:options` field on `Flag` struct for `:select` type — a list of `{label, value}` tuples
- Compile-time validation that `:select` flags must provide `:options`
- Compile-time validation that `:select` default value must be in the `:options` list

## [0.2.0] - 2026-03-19

### Added

- `PhoenixFlags.Error` custom exception for all library-raised errors
- `PhoenixFlags.Type` shared validation module, eliminating duplicated logic between `Flag` and `Entry`
- `update_entry/3` now accepts `:timeout` option for GenServer call timeout
- `Testing.insert_entry/4` infers type from value (boolean, integer, Decimal, string)
- Helpful error message when numeric flag types omit `:default` (e.g. `flag "x", type: :integer`)
- Catch-all `handle_info` clause to prevent GenServer crashes from unexpected messages
- `terminate/2` erases config key on shutdown, signalling "server down" to readers
- Peer notification after flag seeding, so other nodes pick up changes from deploys
- Dashboard `:layout` option to render inside the host app's layout
- `PhoenixFlags.UI.OnMount` hook for mounting dashboard in custom `live_session`
- Conditional compilation for UI modules (`phoenix_live_view` is truly optional)

### Changed

- `get/3` never crashes — returns default when server is not running or restarting
- `all_grouped/0` returns `[]` when server is not running
- Cache stores values and entries in a single atomic `{values, entries}` tuple (one persistent_term key instead of two)
- Metadata updates during seeding are wrapped in `Repo.transaction` for atomicity
- `insert_all` uses `on_conflict: :nothing` to handle concurrent node startups gracefully
- Dashboard uses host app's layout and CSS framework instead of self-contained styles
- `load_cache` crashes on first load in `init` (supervisor retries), rescues on subsequent reloads
- Removed dead `:table` config option from `Config` struct

### Fixed

- SQL injection in `Migration.migrated_version/1` — now uses parameterized query
- Migration V01 now respects the `:prefix` option for table and index creation
- Narrowed `rescue ArgumentError` in `get/3` to only catch persistent_term lookup failures
- `cast_value` logs at debug level for unparseable values instead of silently returning nil

## [0.1.0] - 2026-03-19

### Added

- Initial release
- `use PhoenixFlags` macro for defining configuration modules
- `flag/2` macro for compile-time validated flag declarations
- `PhoenixFlags.Flag` struct with validation for key, type, and default values
- `PhoenixFlags.Entry` Ecto schema with typed value casting and validation
- `PhoenixFlags.Server` GenServer with `:persistent_term` caching
- Declarative flag seeding on startup: insert new, update metadata, remove stale, reset value on type change
- Cluster-aware cache replication via direct node messaging
- Versioned migration system (`PhoenixFlags.Migration`)
- V01 migration: `system_flags` table with key, value, type, category, label, description
- `PhoenixFlags.Testing` module with process-scoped overrides and DB insert helpers
- Auto-generated `Test` submodule in `:test` environment with `put_override/2` and `insert_entry/3`
- `PhoenixFlags.Config` struct for instance configuration
- Support for boolean, integer, decimal, percentage, select, and string value types
- Validation per type on `update_entry/2`
- `all_grouped/0` for admin UI data
- Test sandbox compatibility via `cache_enabled: false`
- Embedded admin dashboard (`PhoenixFlags.Router.flags_dashboard/2`)
- Self-contained LiveView UI with own layout, components, and CSS (no app dependencies)
- Dashboard features: boolean toggle switches, inline edit forms, validation errors, flash messages, dark mode
