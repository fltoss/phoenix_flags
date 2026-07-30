defmodule PhoenixFlags.MigrationTest do
  # These tests run real migrations in a dedicated PostgreSQL schema through
  # a separate (non-sandbox) repo instance, so they must not run async.
  use ExUnit.Case, async: false

  alias PhoenixFlags.TestRepo

  @prefix "pf_migration_test"
  @migration_repo :pf_migration_repo
  # Far away from the real migration versions in priv/test_repo/migrations.
  @initial_migration 99_999_999_999_997
  @v2_migration 99_999_999_999_998
  @upgrade_migration 99_999_999_999_999

  # The migration an app generated on install: up() migrates to the latest
  # version the installed package knows about.
  defmodule InitialMigration do
    use Ecto.Migration

    def up, do: PhoenixFlags.Migration.up(prefix: "pf_migration_test")
    def down, do: PhoenixFlags.Migration.down(version: 1, prefix: "pf_migration_test")
  end

  defmodule InitialToV2 do
    use Ecto.Migration

    def up, do: PhoenixFlags.Migration.up(version: 2, prefix: "pf_migration_test")
    def down, do: PhoenixFlags.Migration.down(version: 1, prefix: "pf_migration_test")
  end

  defmodule UpgradeToV2 do
    use Ecto.Migration

    def up, do: PhoenixFlags.Migration.up(version: 2, prefix: "pf_migration_test")
    def down, do: PhoenixFlags.Migration.down(version: 2, prefix: "pf_migration_test")
  end

  defmodule UpgradeToV3 do
    use Ecto.Migration

    def up, do: PhoenixFlags.Migration.up(version: 3, prefix: "pf_migration_test")
    def down, do: PhoenixFlags.Migration.down(version: 3, prefix: "pf_migration_test")
  end

  setup do
    start_supervised!(
      {TestRepo, name: @migration_repo, pool: DBConnection.ConnectionPool, pool_size: 2}
    )

    previous_repo = TestRepo.put_dynamic_repo(@migration_repo)
    on_exit(fn -> TestRepo.put_dynamic_repo(previous_repo) end)

    # Clean up any leftovers from a previously failed run.
    reset_migration_state()

    :ok
  end

  test "migrates up, rolls back partially and fully, and tracks the version" do
    TestRepo.query!("CREATE SCHEMA #{@prefix}")

    migrations = [{@initial_migration, InitialToV2}, {@upgrade_migration, UpgradeToV3}]
    migrator_opts = [log: false, dynamic_repo: @migration_repo]

    # Fresh install: up to the current version
    assert [_, _] = Ecto.Migrator.run(TestRepo, migrations, :up, [all: true] ++ migrator_opts)

    assert table_exists?("system_flags")
    assert table_exists?("system_flags_audit")

    # V03 widened the value columns to text
    assert column_type("system_flags", "value") == "text"
    assert column_type("system_flags_audit", "old_value") == "text"
    assert column_type("system_flags_audit", "new_value") == "text"

    # The version lives in the meta table now; the legacy comment is cleared
    assert meta_version() == PhoenixFlags.Migration.current_version()
    assert comment_version() == nil

    # Partial rollback to V2: meta table dropped, version back in the comment
    assert [_] = Ecto.Migrator.run(TestRepo, migrations, :down, [step: 1] ++ migrator_opts)

    refute table_exists?("system_flags_meta")
    assert comment_version() == "2"
    assert column_type("system_flags", "value") == "character varying"

    # Upgrading again picks the version up from the comment
    assert [_] = Ecto.Migrator.run(TestRepo, migrations, :up, [all: true] ++ migrator_opts)

    assert meta_version() == 3
    assert comment_version() == nil

    # Full rollback used to fail with invalid SQL (COMMENT ON TABLE IF EXISTS)
    assert [_, _] =
             Ecto.Migrator.run(TestRepo, migrations, :down, [all: true] ++ migrator_opts)

    refute table_exists?("system_flags")
    refute table_exists?("system_flags_audit")
    refute table_exists?("system_flags_meta")

    reset_migration_state()
  end

  test "a 0.5.0 app's migration folder runs seamlessly on a fresh database" do
    TestRepo.query!("CREATE SCHEMA #{@prefix}")

    # What an upgraded app's priv/repo/migrations contains: the original
    # install migration (unpinned up/0), the 0.5.0 upgrade pinned to V2, and
    # the newly generated V3 upgrade. On a fresh database the first migration
    # now builds V3 directly, so the two upgrade migrations must be no-ops.
    migrations = [
      {@initial_migration, InitialMigration},
      {@v2_migration, UpgradeToV2},
      {@upgrade_migration, UpgradeToV3}
    ]

    migrator_opts = [log: false, dynamic_repo: @migration_repo]

    assert [_, _, _] =
             Ecto.Migrator.run(TestRepo, migrations, :up, [all: true] ++ migrator_opts)

    assert table_exists?("system_flags")
    assert table_exists?("system_flags_audit")
    assert meta_version() == PhoenixFlags.Migration.current_version()
    assert column_type("system_flags", "value") == "text"

    # And the whole chain rolls back cleanly: V3 → comment "2" → comment "1"
    # → everything dropped.
    assert [_, _, _] =
             Ecto.Migrator.run(TestRepo, migrations, :down, [all: true] ++ migrator_opts)

    refute table_exists?("system_flags")
    refute table_exists?("system_flags_audit")
    refute table_exists?("system_flags_meta")

    reset_migration_state()
  end

  defp reset_migration_state do
    TestRepo.query!("DROP SCHEMA IF EXISTS #{@prefix} CASCADE")

    TestRepo.query!("DELETE FROM schema_migrations WHERE version = ANY($1)", [
      [@initial_migration, @v2_migration, @upgrade_migration]
    ])
  end

  defp table_exists?(table) do
    %{rows: [[exists]]} =
      TestRepo.query!("SELECT to_regclass($1) IS NOT NULL", ["#{@prefix}.#{table}"])

    exists
  end

  defp column_type(table, column) do
    %{rows: [[type]]} =
      TestRepo.query!(
        """
        SELECT data_type FROM information_schema.columns
        WHERE table_schema = $1 AND table_name = $2 AND column_name = $3
        """,
        [@prefix, table, column]
      )

    type
  end

  defp meta_version do
    %{rows: rows} =
      TestRepo.query!(
        "SELECT value FROM #{@prefix}.system_flags_meta WHERE key = 'schema_version'"
      )

    case rows do
      [[version]] -> String.to_integer(version)
      _ -> nil
    end
  end

  defp comment_version do
    %{rows: rows} =
      TestRepo.query!(
        """
        SELECT obj_description(c.oid)
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relname = 'system_flags' AND n.nspname = $1
        """,
        [@prefix]
      )

    case rows do
      [[version]] -> version
      _ -> nil
    end
  end
end
