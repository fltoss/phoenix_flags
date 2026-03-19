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
  @current_version 1

  @doc """
  Runs migrations up to the specified version (or the latest).
  """
  def up(opts \\ []) do
    version = Keyword.get(opts, :version, @current_version)
    prefix = Keyword.get(opts, :prefix, "public")
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
    current = migrated_version(prefix)

    if current > version do
      for v <- current..max(version + 1, @initial_version)//-1 do
        pad = String.pad_leading(Integer.to_string(v), 2, "0")
        module = Module.concat([__MODULE__, "V#{pad}"])
        module.down(%{prefix: prefix})
      end

      if version < @initial_version do
        execute("COMMENT ON TABLE IF EXISTS #{prefix}.system_flags IS NULL")
      else
        set_version(prefix, version)
      end
    end
  end

  @doc """
  Returns the current migrated version by reading the table comment.
  Returns 0 if the table doesn't exist or has no version comment.
  """
  def migrated_version(prefix \\ "public") do
    query = """
    SELECT obj_description(c.oid)
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname = 'system_flags'
    AND n.nspname = $1
    """

    case repo().query(query, [prefix]) do
      {:ok, %{rows: [[version]]}} when is_binary(version) ->
        String.to_integer(version)

      _ ->
        0
    end
  end

  @doc false
  def current_version, do: @current_version

  defp set_version(prefix, version) when is_integer(version) do
    execute("COMMENT ON TABLE #{prefix}.system_flags IS '#{version}'")
  end
end
