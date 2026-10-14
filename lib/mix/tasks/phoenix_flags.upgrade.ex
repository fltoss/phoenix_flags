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
    - `0.6.0` — generates a migration that calls
      `PhoenixFlags.Migration.up(version: 3)`, widening the value columns
      from `varchar(255)` to `text` (encrypted secrets easily exceed 255
      characters) and moving the schema version into the new
      `system_flags_meta` table.
    - `0.9.0` — generates a migration that calls
      `PhoenixFlags.Migration.up(version: 4)`, adding the
      `system_flag_targets` and `system_flag_target_conditions` tables used by
      targeting rules.
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

    # One row per release that changed the schema: the release, the migration
    # version it needs, and what to tell the person upgrading.
    @steps [
      {"0.5.0", 2,
       """
       phoenix_flags 0.5.0 adds the `system_flags_audit` table (for the audit log)
       and enables the `:secret` flag type.
       """},
      {"0.6.0", 3,
       """
       phoenix_flags 0.6.0 widens the flag and audit value columns from
       varchar(255) to text (encrypted secrets exceed 255 characters) and
       moves the schema version into the new system_flags_meta table.
       """},
      {"0.9.0", 4,
       """
       phoenix_flags 0.9.0 adds targeting rules: force a flag's value for a
       specific user, company, or any attribute you pass in the request
       context. Two new tables back it — system_flag_targets and
       system_flag_target_conditions. Existing flags are unaffected until you
       add a rule.
       """}
    ]

    @impl true
    def igniter(igniter) do
      %{from: from, to: to} = igniter.args.positional

      upgrades =
        Map.new(@steps, fn {release, version, notice} ->
          {release, [&migration_step(&1, &2, version, notice)]}
        end)

      Igniter.Upgrades.run(igniter, from, to, upgrades, igniter.args.options)
    end

    defp migration_step(igniter, _opts, version, notice) do
      {igniter, repos} = Igniter.Libs.Ecto.list_repos(igniter)
      name = "upgrade_system_flags_v#{version}"

      case List.first(repos) do
        nil ->
          Igniter.add_warning(
            igniter,
            "phoenix_flags: no Ecto repo found; skipping the v#{version} migration generator. " <>
              "Generate it manually with `mix ecto.gen.migration #{name}` " <>
              "and have it call `PhoenixFlags.Migration.up(version: #{version})`."
          )

        repo ->
          igniter
          |> Igniter.Libs.Ecto.gen_migration(repo, name,
            body: """
              def up, do: PhoenixFlags.Migration.up(version: #{version})
              def down, do: PhoenixFlags.Migration.down(version: #{version})
            """,
            on_exists: :skip,
            timestamp: timestamp(version)
          )
          |> Igniter.add_notice(
            notice <> "A migration was generated — run `mix ecto.migrate` to apply it."
          )
      end
    end

    # Igniter stamps a migration to the second, so the steps of one upgrade
    # across several releases would share a version, which Ecto refuses to run.
    # Offsetting by the schema version keeps them distinct and in order.
    defp timestamp(version) do
      {{year, month, day}, {hour, minute, second}} =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(version)
        |> NaiveDateTime.to_erl()

      :io_lib.format("~4..0B~2..0B~2..0B~2..0B~2..0B~2..0B", [
        year,
        month,
        day,
        hour,
        minute,
        second
      ])
      |> IO.iodata_to_binary()
    end
  end
end
