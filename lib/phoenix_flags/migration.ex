defmodule PhoenixFlags.Migration do
  @moduledoc """
  Migrations for PhoenixFlags.

  ## Usage

  Generate a migration in your app:

      mix ecto.gen.migration add_system_flags

  Then call the migration helpers:

      defmodule MyApp.Repo.Migrations.AddSystemFlags do
        use Ecto.Migration

        def up, do: PhoenixFlags.Migration.up()
        def down, do: PhoenixFlags.Migration.down(version: 1)
      end

  When the package releases a new version with schema changes, generate
  another migration and specify the target version:

      defmodule MyApp.Repo.Migrations.UpgradeSystemFlagsToV2 do
        use Ecto.Migration

        def up, do: PhoenixFlags.Migration.up(version: 2)
        def down, do: PhoenixFlags.Migration.down(version: 2)
      end

  ## Options

  - `:version` — target version to migrate to (default: latest)
  - `:prefix` — PostgreSQL schema prefix (default: `"public"`)
  """

  use Ecto.Migration

  @initial_version 1
  @current_version 4
  # Version that introduced the system_flags_meta table. From this version on
  # the schema version lives in that table; below it, in the table comment.
  @meta_version 3
  @prefix_pattern ~r/^[a-z_][a-z0-9_]*$/

  @doc """
  Runs migrations up to the specified version (or the latest).
  """
  def up(opts \\ []) do
    version = Keyword.get(opts, :version, @current_version)
    prefix = Keyword.get(opts, :prefix, "public")
    validate_prefix!(prefix)
    current = migrated_version(prefix)

    if current < version do
      for v <- (current + 1)..version do
        pad = String.pad_leading(Integer.to_string(v), 2, "0")
        module = Module.concat([__MODULE__, "V#{pad}"])
        module.up(%{prefix: prefix})
      end

      set_version(prefix, version)
    end
  end

  @doc """
  Rolls back migrations to the specified version (or removes everything).
  """
  def down(opts \\ []) do
    version = Keyword.get(opts, :version, @initial_version) - 1
    prefix = Keyword.get(opts, :prefix, "public")
    validate_prefix!(prefix)
    current = migrated_version(prefix)

    if current > version do
      for v <- current..max(version + 1, @initial_version)//-1 do
        pad = String.pad_leading(Integer.to_string(v), 2, "0")
        module = Module.concat([__MODULE__, "V#{pad}"])
        module.down(%{prefix: prefix})
      end

      # A rollback below the initial version drops the system_flags table
      # (V01.down), taking the version comment with it — nothing to reset.
      if version >= @initial_version do
        set_version(prefix, version)
      end
    end
  end

  @doc """
  Returns the current migrated version.

  Reads the `system_flags_meta` table (V3+), falling back to the
  `system_flags` table comment used by older versions. Returns 0 if the
  tables don't exist or no version is recorded.
  """
  def migrated_version(prefix \\ "public") do
    validate_prefix!(prefix)

    read_meta_version(prefix) || read_comment_version(prefix) || 0
  end

  @doc false
  def current_version, do: @current_version

  # Existence is probed via to_regclass instead of just querying the table:
  # a failed query would abort the surrounding migration transaction.
  defp read_meta_version(prefix) do
    with {:ok, %{rows: [[true]]}} <-
           repo().query("SELECT to_regclass($1) IS NOT NULL", ["#{prefix}.system_flags_meta"]),
         {:ok, %{rows: [[version]]}} <-
           repo().query(
             "SELECT value FROM #{prefix}.system_flags_meta WHERE key = 'schema_version'"
           ) do
      parse_version(version)
    else
      _ -> nil
    end
  end

  defp read_comment_version(prefix) do
    query = """
    SELECT obj_description(c.oid)
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname = 'system_flags'
    AND n.nspname = $1
    """

    case repo().query(query, [prefix]) do
      {:ok, %{rows: [[version]]}} -> parse_version(version)
      _ -> nil
    end
  end

  defp parse_version(version) when is_binary(version) do
    case Integer.parse(version) do
      {v, ""} -> v
      _ -> nil
    end
  end

  defp parse_version(_version), do: nil

  # The target store is decided by the version number, not by probing the
  # database: migration DSL commands are queued and only flush when the host
  # migration finishes, so at this point a freshly created meta table is not
  # visible yet. Writing to the meta table for >= @meta_version is safe —
  # V03 creates it earlier in the same command queue.
  defp set_version(prefix, version) when is_integer(version) and version >= @meta_version do
    execute("""
    INSERT INTO #{prefix}.system_flags_meta (key, value)
    VALUES ('schema_version', '#{version}')
    ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value
    """)
  end

  defp set_version(prefix, version) when is_integer(version) do
    execute("COMMENT ON TABLE #{prefix}.system_flags IS '#{version}'")
  end

  defp validate_prefix!(prefix) do
    unless Regex.match?(@prefix_pattern, prefix) do
      raise ArgumentError,
            "PhoenixFlags.Migration: invalid prefix #{inspect(prefix)}, " <>
              "must match #{inspect(@prefix_pattern)}"
    end
  end
end
