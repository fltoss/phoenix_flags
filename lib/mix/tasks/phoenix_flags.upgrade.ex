if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.PhoenixFlags.Upgrade do
    @moduledoc """
    Applies per-version upgrade steps for PhoenixFlags.

    Not invoked directly — `mix igniter.upgrade phoenix_flags` composes this
    task automatically, passing `<from> <to>` versions. For each version bump
    between `from` and `to`, the matching upgrader runs (e.g. generating a new
    migration).

    ## Upgrade steps

    - `0.5.0` — generates a migration that calls
      `PhoenixFlags.Migration.up(version: 2)`, adding the
      `system_flags_audit` table used by the audit log and enabling the
      `:secret` flag type.
    """
    use Igniter.Mix.Task

    @impl true
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :phoenix_flags,
        adds_deps: [],
        installs: [],
        example: "mix igniter.upgrade phoenix_flags",
        positional: [:from, :to],
        schema: [],
        defaults: [],
        aliases: [],
        required: []
      }
    end

    @impl true
    def igniter(igniter) do
      %{from: from, to: to} = igniter.args.positional
      options = igniter.args.options

      upgrades = %{
        "0.5.0" => [&upgrade_to_v2_migration/2]
      }

      Igniter.Upgrades.run(igniter, from, to, upgrades, options)
    end

    defp upgrade_to_v2_migration(igniter, _opts) do
      {igniter, repos} = Igniter.Libs.Ecto.list_repos(igniter)

      case List.first(repos) do
        nil ->
          Igniter.add_warning(
            igniter,
            "phoenix_flags: no Ecto repo found; skipping the v2 migration generator. " <>
              "Generate it manually with `mix ecto.gen.migration upgrade_system_flags_v2` " <>
              "and have it call `PhoenixFlags.Migration.up(version: 2)`."
          )

        repo ->
          igniter
          |> Igniter.Libs.Ecto.gen_migration(repo, "upgrade_system_flags_v2",
            body: """
              def up, do: PhoenixFlags.Migration.up(version: 2)
              def down, do: PhoenixFlags.Migration.down(version: 2)
            """,
            on_exists: :skip
          )
          |> Igniter.add_notice("""
          phoenix_flags 0.5.0 adds the `system_flags_audit` table (for the audit log)
          and enables the `:secret` flag type. A migration was generated — run
          `mix ecto.migrate` to apply it.
          """)
      end
    end
  end
end
