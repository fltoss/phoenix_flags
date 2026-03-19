# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-03-19

### Added

- Initial release
- `use PhoenixFlags` macro for defining configuration modules
- `PhoenixFlags.Entry` Ecto schema with typed value casting and validation
- `PhoenixFlags.Server` GenServer with `:persistent_term` caching
- Cluster-aware cache replication via direct node messaging
- Versioned migration system (`PhoenixFlags.Migration`)
- V01 migration: `system_flags` table with key, value, type, category, label, description
- `PhoenixFlags.Testing` module with process-scoped overrides and DB insert helpers
- `PhoenixFlags.Config` struct for instance configuration
- Support for boolean, integer, decimal, percentage, select, and string value types
- Validation per type on `update_entry/2`
- `all_grouped/0` for admin UI data
- Test sandbox compatibility via `cache_enabled: false`
