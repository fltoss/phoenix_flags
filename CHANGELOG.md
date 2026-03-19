# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
