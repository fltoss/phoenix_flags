# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.9.0] - 2026-08-25

### Added

- **Targeting rules: force a flag's value for a specific key.** Pass a context of
  attributes and let ordered rules override the value when it matches — onboard a
  beta customer, unblock one account, raise a limit for one tenant, without a
  deploy.

  ```elixir
  # once per request, in a plug or on_mount hook
  PhoenixFlags.put_context(user_id: user.id, company_id: user.company_id)

  # unchanged call sites are now targeted
  MyApp.SystemConfig.get("enable_benefits", false)     #=> true for company 123
  MyApp.SystemConfig.variant("checkout_flow", user.id) #=> pinned arm for user 7

  # rules, from the dashboard or in code
  MyApp.SystemConfig.put_target("enable_benefits",
    conditions: [[attribute: :company_id, operator: :in, values: [123, 456]]],
    value: "true"
  )
  ```

  **Requires migration V4** — `PhoenixFlags.Migration.up(version: 4)`, or
  `mix igniter.upgrade phoenix_flags` to generate it. Existing flags are
  unaffected until a rule is added.

  This is the attribute-targeting half of the [AWS AppConfig
  model](https://docs.aws.amazon.com/appconfig/latest/userguide/appconfig-creating-multi-variant-feature-flags-rules.html)
  deferred when `:variant` shipped in 0.7.0. Rules are structured rows rather
  than a string expression DSL, so they can be validated properly and edited in a
  UI. Conditions live in their own table rather than a `jsonb` column: `jason` is
  declared optional and unused in `lib/`, and a JSON column would make a JSON
  library effectively required.

  Details:

  - **Applies to any flag type.** A rule forces a value, validated against that
    flag's type through the same changeset a dashboard save uses. A `:variant`
    rule names a declared arm rather than a weights string.
  - **Precedence**: a test stub, then a matching rule, then the stored value or
    the weighted split. A rule therefore overrides an A/B split, which is the
    point of pinning a customer to one arm.
  - **Operators** `:in`, `:not_in`, `:eq`, `:starts_with`. Conditions within a
    rule are ANDed; rules are checked in order and the first match wins.
  - **Everything compares as strings**, so `%{company_id: 123}` matches `"123"`
    and `:company_id` matches `"company_id"` — consistent with every flag value
    being stored as a string.
  - **A missing attribute never matches**, `:not_in` included: "everyone except
    these" must not sweep in callers we know nothing about.
  - **`:secret` flags cannot be targeted** — the rule value would sit in the
    targets table as plaintext, defeating the encryptor.
  - **Cost when unused is one `:persistent_term` read plus a map lookup**, and a
    flag with no rules never reads the context. That ordering came from
    measurement: checking the context first measured *slower* than the read it
    was avoiding. See `docs/benchmarks.md`.
  - **The context is per-process and not inherited** by `Task.async/1` and
    friends; documented, with `context: PhoenixFlags.context()` as the answer.
  - Cluster replication is free: a rule write triggers a full cache reload and
    notifies peers, which reload the same way they already do.

- `PhoenixFlags.Context` — `put/1`, `merge/1`, `get/0`, `clear/0`, with
  `PhoenixFlags.put_context/1` and friends as shorthands.
- `PhoenixFlags.Target` and `PhoenixFlags.Target.Condition`, with `resolve/2` and
  `matches?/2` as pure, fuzz-tested functions.
- Generated `targets/1`, `put_target/2` and `delete_target/1` on every config
  module; `get/2` becomes `get/3` with a `:context` option, and `variant/3`
  accepts `:context` too.
- The dashboard's edit dialog lists a flag's rules and can add or delete them.
  The forced-value input is constrained to what the flag's type allows — a
  dropdown of declared variants for `:variant`, true/false for `:boolean`.

### Fixed

- **A single bad `:variant` weights string produced two identical changeset
  errors**, which the dashboard rendered twice. `Type.validate_value/2` and the
  declared-name check both parsed the value and both reported the same failure;
  the name check now skips when the value has already been rejected.

### Changed

- **Benchmarks use their own `phoenix_flags_bench` database**, created and
  migrated on first run. `bench/bench_helper.exs` pointed at the test database
  and runs outside the Ecto sandbox, so benchmark writes committed and broke the
  next `mix test`. The README documented that as a trap; it is now simply gone.


## [0.8.0] - 2026-08-25

### Changed

- **The dashboard editor is now a modal dialog** instead of an inline form that
  replaced the row. Opens from the row's Edit button; closes on Save, Cancel, the
  ×, Escape, or a backdrop click. Keyboard focus moves into the dialog on open,
  and a validation error keeps it open with the message in place.

  The dialog is rendered once for whichever flag is being edited, derived from
  the current entries rather than held in its own assign, so a cluster update
  cannot leave it showing a stale value. `:secret` flags now go through the same
  dialog as everything else rather than a bespoke inline form.

  Dead CSS for the old inline editor (`.pf-row-editing`, `.pf-edit-actions`,
  `.pf-input-wrap`) has been removed.

### Fixed

- **Editing `priv/static/app.css` had no effect.** The stylesheet is read into a
  module attribute at compile time, but nothing declared it as an
  `@external_resource` — so Elixir did not know the module depended on it and
  never recompiled. The old CSS stayed baked into the beam and kept being served.
  Found while adding the modal styles, which silently did not appear.

- **The edit dialog focused the close button on open.** `JS.focus_first/0` walks
  DOM order and reached the header's × before any input, which put keyboard focus
  in the wrong place and rendered the × with a focus ring. Focus is now scoped to
  the dialog body.

- Modal styling: the weight rows had a 120px label gutter that left a dead gap
  for short labels, and a 92px right-aligned input put the value underneath the
  native spinner. Labels and inputs now sit at opposite ends of the row with the
  value padded clear of the spinner, and the footer has enough contrast to read
  as a footer in dark mode. The close button's focus ring is `:focus-visible`
  only, so it no longer shows for pointer users.

- **`docs/benchmarks.md` was linked from the README but missing from `:extras`,**
  so the link resolved on GitHub but not on hexdocs, and `mix docs` warned.

- **The `mix run dev.exs` dashboard rendered but was completely inert.** Clicking
  Edit or a toggle did nothing, with `window.LiveView is undefined` in the
  console. The inline dev bundle wraps `phoenix.min.js` and
  `phoenix_live_view.min.js` in an arrow function, and those are esbuild IIFEs of
  the form `var LiveView = (() => {...})()` — so inside that wrapper they are
  ordinary function-scoped locals, never globals. Reading them as
  `window.LiveView` / `window.Phoenix` therefore yielded `undefined` and no
  LiveSocket was ever constructed. Now references the local bindings, verified by
  evaluating the served bundle under Node with a DOM shim: it constructs a
  LiveSocket, where the previous bundle threw the exact reported error.

  Dev tooling only — the packaged library is unaffected, and the dashboard's
  server-side behaviour was always covered by the LiveView tests. But it means
  manual browser checks of the dashboard were never actually exercising
  interactivity.

- `dev.exs` now asserts at load time that each bundled asset still begins with
  the expected `var Phoenix=` / `var LiveView=` binding, so an upstream rename or
  format change fails loudly instead of silently producing an inert page again.

- `.formatter.exs` now includes `dev.exs` and `bench/`. They sat outside the
  input globs, so `mix format --check-formatted` in CI never checked them.

### Added

- The README's Development section now covers running the dashboard locally,
  running the suite, reproducing CI exactly, driving the API from a script (and
  why `iex -S mix run dev.exs` never reaches a prompt), trying the library in
  your own app via a path dependency, and the test-database pollution trap in
  `bench/bench_helper.exs`.
- `usage-rules.md` gains an Admin dashboard section, leading with the fact that
  the dashboard ships no authentication and must be guarded at both the pipeline
  and `:on_mount` layers.

## [0.7.1] - 2026-08-25

Bug fixes from a review of the 0.7.0 A/B feature, plus two crash paths that
predate it. Every fix below is covered by a test that was verified to fail
without it.

### Fixed

- **Hash parts could be re-partitioned, aliasing two experiments together.**
  The seed, flag key and identity were joined with `":"`, so
  `variant("exp", "org:123")` and `variant("exp:org", "123")` hashed identically
  — a 100% collision rate, not a rare one. Composite identities like `"org:123"`
  are common enough for this to bite. Parts are now length-prefixed. Distribution
  is unchanged (50.02/49.98 over 20k identities); collisions dropped from
  5000/5000 to chance.

  This changes every assignment relative to 0.7.0. Since 0.7.0 was tagged but
  never published to Hex, nobody should be affected in practice — but if you
  installed it from git, expect your population to reshuffle once.

- **A changed variant set kept assigning removed variants.** Seeding deliberately
  leaves the stored weights alone so a runtime rollout survives a deploy. But
  when the declared *set* of variants changed, the stored split still named
  variants the code no longer had, and `variant/3` went on assigning them —
  crashing callers that pattern match on the declared names. Seeding now resets
  the split (with a warning) when the set differs, mirroring the existing reset
  on a type change. Comparison is by set, so a rollout survives both a
  reordering and any weight change.

- **`variant/3` raised on an unusable identity.** A `nil` identity is a data
  condition — an anonymous visitor, a record without an id — not necessarily a
  coding mistake, and it took down the caller's process. It now warns and returns
  `:default`, consistent with how `get/3` handles a failed read.
  `PhoenixFlags.Variant.assign/4` stays strict for direct callers.

- **A forged dashboard weight crashed the LiveView.** A non-string value in
  `entry[variants][...]` reached string interpolation and raised
  `Protocol.UndefinedError`. It is now coerced to `0`, which surfaces as an
  ordinary "must total 100" field error.

- **A forged `pf-save` for an unknown key crashed the dashboard.**
  `update_entry/4` returns `{:error, :not_found}` for a key that is not in the
  table; that bound as `changeset` and `to_form/2` raised on it. The dashboard
  also gained a catch-all `handle_event/3`, so an unknown event name or a missing
  field no longer takes the view down for want of a matching clause.

- **Log statements inside rescue handlers could themselves raise** — *predates
  0.7.0*. Several interpolated the flag key directly, and `String.Chars` is
  undefined for a map, tuple or pid. Because these sat inside `rescue` blocks,
  the failure escaped to the caller: `get("some_key")` with a map key crashed
  with `Protocol.UndefinedError` instead of returning the default. All such log
  statements now use `inspect/1`, which is also unambiguous for keys containing
  spaces. Log message format changed accordingly.

- **A non-string key reached the database** — *predates 0.7.0*. `get/3`,
  `update_entry/4` and `variant/3` now screen the key before querying, rather
  than relying on a rescue to mop up an `Ecto.Query.CastError`.

### Changed

- **A stored split must name every declared variant.** Previously a subset was
  accepted, so `"a=100"` could be saved for a two-variant flag — and then be
  reset by the next restart, because seeding reconciles the stored set against
  the declaration. Writes are now durable or rejected; use a weight of `0` to
  switch a variant off.

- **Declaration options that would be ignored are now rejected**, the same
  reasoning as `PhoenixFlags.Config.new!/1` refusing unknown keys: `:default` on
  a `:variant` flag (its value comes from `:variants`), and `:ttl` or `:seed` on
  a non-variant flag.

### Added

- `test/phoenix_flags/variant_robustness_test.exs` — regression tests for each
  fix above, plus a fuzz suite that throws ~40 malformed inputs (separator abuse,
  unicode, huge and negative weights, wrong types) at `Variant.parse/2`,
  `parse_weights/1`, `Entry.cast_value/2` and `Entry.changeset/3`, asserting they
  only ever return and never raise. The log-statement bug above was found this
  way.


## [0.7.0] - 2026-08-25

### Added

- **A/B testing via a new `:variant` flag type.** A `:variant` flag resolves to a
  different value per caller, chosen by a consistent hash of an identity you
  supply, so a given user sees a stable experience and results stay analysable.

  ```elixir
  flag "checkout_flow",
    type: :variant,
    category: "experiments",
    label: "Checkout flow experiment",
    ttl: nil,                    # nil (default) = assignment never expires
    variants: [{"Control", "control", 90}, {"New flow", "new_flow", 10}]
  ```

  ```elixir
  MyApp.SystemConfig.variant("checkout_flow", user.id)   #=> "control"
  ```

  Weights are whole numbers totalling 100, stored as the flag's value
  (`"control=90,new_flow=10"`), so a rollout can go 5% → 15% → 40% → 100% from
  the dashboard with no deploy. **No migration is required** — `system_flags.type`
  is an unconstrained string column and `value` is already `text`.

  Modelled on [AWS AppConfig traffic
  splitting](https://docs.aws.amazon.com/appconfig/latest/userguide/appconfig-creating-multi-variant-feature-flags-rules.html),
  with one deliberate difference. AppConfig evaluates each variant as an
  independent `(split pct::N by::$id)` rule, first match wins over a shared hash,
  which means two variants at `pct::20` produce `A: 20%, B: 0%` — a footgun their
  own docs document. A single ordered weight table makes buckets disjoint by
  construction and lets the total be validated.

  Details:

  - **Sticky rollouts.** Buckets are cumulative in declaration order, so growing
    a variant at the expense of the next one moves only the boundary between
    them. Verified over 20k identities: going `90/10` → `80/20` moves nobody out
    of `new_flow`. Reordering `:variants`, changing `:seed`, or a `:ttl` rollover
    all reshuffle the population, and the docs say so.
  - **`ttl:`** (milliseconds, `nil` by default and meaning permanent) folds a time
    window into the hash so each caller is re-rolled once per window. Windows are
    offset per identity, so the population does not all flip at once. Stateless —
    no rows stored, no database call.
  - **Independence.** The flag key is part of the hash input, so concurrent
    experiments do not correlate. `seed:` re-randomises everyone, for restarting
    an experiment on the same flag.
  - **SHA-256, not `:erlang.phash2/2`.** `phash2` is not guaranteed stable across
    OTP major versions, and an OTP upgrade must not silently reshuffle a live
    experiment. Costs ~0.5 us per assignment; see `docs/benchmarks.md`.
  - **`get/2` raises** for a `:variant` flag, naming `variant/3`, rather than
    leaking a `%PhoenixFlags.Variant{}` into application code. Benchmarked at no
    measurable cost to ordinary reads.
  - **A missing identity raises.** `nil` (or anything not a non-empty string or
    integer) would put every caller in the same bucket, which is an invisible
    bug, so it fails loudly.
  - **Dashboard editor** with one input per variant and a live running total that
    must reach 100.
  - **Opt-in exposure events.** `variant/3` emits nothing by default; pass
    `telemetry: true` for `[:phoenix_flags, :variant, :assigned]`. `:telemetry` is
    now a declared dependency — it was previously only transitive.

- `PhoenixFlags.Variant` — `parse/2`, `parse_weights/1`, `serialize/1`, `assign/4`.
- Generated `variant/3` and `variants/1` on every config module.

### Fixed

- **`usage-rules.md` documented a function that does not exist.** It described
  `Test.put_override/2`; the generated helper is `Test.stub/2`. Since
  `usage-rules.md` ships in the package and is consumed by coding agents, this
  was actively misleading.
- Dashboard edit forms now carry an `id`, which LiveView needs for form recovery
  after a reconnect. Previously it warned about this in tests.


### Changed

- **Unexpected stored boolean values now warn instead of failing silently.**
  `cast_value/2` was `value == "true"`, so a value that was neither `"true"`
  nor `"false"` — only reachable via a hand-edited row or a data migration,
  since `changeset/3` rejects anything else — read as `false` with no signal.
  It still returns `false` (for a boolean flag, failing closed beats returning
  `nil` and changing what `get(key) == false` means), but now logs a warning
  like the integer and decimal casts already did.

### Internal

No behaviour change; all of these are covered by the existing suite.

- Both write paths now build their changeset through one `value_changeset/3`.
  The encrypt-then-validate sequence was duplicated across the cached and
  uncached paths, which is why `:select` membership went unchecked on both at
  once.
- Removed a dead `rescue ArgumentError` in `read_persistent_term/2`;
  `:persistent_term.get/2` returns the default for a missing key rather than
  raising. Documented why the `get/1` call sites do still need theirs.
- Documented the deliberate asymmetry in `update_in_caller/4`: unlike the
  cached path it has no `rescue`, because with no GenServer to keep alive a
  database error should reach the caller rather than be flattened into an
  error changeset.
- `PhoenixFlags.Config` derives both `defstruct` and its accepted-option list
  from a single `@fields` attribute; the two were maintained side by side and
  could drift.
- Named the `999_999` sort sentinel in `all_grouped/1`.
- Added `PhoenixFlags.EntryTest` covering `cast_value/2` and `changeset/3`,
  which had no direct unit tests.

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
