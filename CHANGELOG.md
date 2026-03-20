# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
