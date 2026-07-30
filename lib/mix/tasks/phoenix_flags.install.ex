if Code.ensure_loaded?(Igniter) do
  defmodule Mix.Tasks.PhoenixFlags.Install do
    @moduledoc """
    Installs PhoenixFlags into your project.

    ## What it does

    1. Detects your Ecto repo
    2. Generates `lib/my_app/system_config.ex` with `use PhoenixFlags`
    3. Generates the `create_system_flags` migration
    4. Adds `cache_enabled: false` to `config/test.exs`
    5. Adds the module to your application supervision tree

    ## Usage

        mix phoenix_flags.install
    """
    use Igniter.Mix.Task

    @impl true
    def info(_argv, _composing_task) do
      %Igniter.Mix.Task.Info{
        group: :phoenix_flags,
        adds_deps: [],
        installs: [],
        example: "mix phoenix_flags.install"
      }
    end

    @impl true
    def igniter(igniter) do
      otp_app = Igniter.Project.Application.app_name(igniter)

      {igniter, repos} = Igniter.Libs.Ecto.list_repos(igniter)
      repo = List.first(repos)

      unless repo do
        raise "No Ecto repo found. Please create one first."
      end

      module_name = Igniter.Project.Module.module_name(igniter, "SystemConfig")

      igniter
      |> Igniter.Project.Module.create_module(module_name, """
        use PhoenixFlags,
          otp_app: #{inspect(otp_app)},
          repo: #{inspect(repo)}

        # flag "enable_feature",
        #   type: :boolean,
        #   default: "false",
        #   category: "features",
        #   label: "Enable Feature",
        #   description: "Toggle this feature on or off."
      """)
      |> Igniter.Libs.Ecto.gen_migration(repo, "create_system_flags",
        body: """
          def up, do: PhoenixFlags.Migration.up()
          def down, do: PhoenixFlags.Migration.down(version: 1)
        """
      )
      |> Igniter.Project.Config.configure_new(
        otp_app,
        module_name,
        [:cache_enabled],
        false,
        file: "test.exs"
      )
      |> Igniter.Project.Application.add_new_child(module_name)
    end
  end
end
