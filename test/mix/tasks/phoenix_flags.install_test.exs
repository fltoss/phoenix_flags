defmodule Mix.Tasks.PhoenixFlags.InstallTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  defp project_with_repo do
    test_project(
      files: %{
        "lib/test/repo.ex" => """
        defmodule Test.Repo do
          use Ecto.Repo, otp_app: :test, adapter: Ecto.Adapters.Postgres
        end
        """
      }
    )
  end

  test "creates the config module, a pinned migration and the test config" do
    igniter = Igniter.compose_task(project_with_repo(), "phoenix_flags.install", [])

    igniter
    |> assert_creates("lib/test/system_config.ex")
    |> assert_creates("config/test.exs", """
    import Config
    config :test, Test.SystemConfig, cache_enabled: false
    """)

    migration =
      igniter.rewrite
      |> Rewrite.sources()
      |> Enum.find(&String.ends_with?(&1.path, "_create_system_flags.exs"))

    assert migration, "no create_system_flags migration was generated"

    assert Rewrite.Source.get(migration, :content) =~
             "def up, do: PhoenixFlags.Migration.up()\n"
  end
end
