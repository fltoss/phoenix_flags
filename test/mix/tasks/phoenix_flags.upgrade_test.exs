defmodule Mix.Tasks.PhoenixFlags.UpgradeTest do
  use ExUnit.Case, async: true

  import Igniter.Test

  test "an upgrade across several releases writes one migration each, with distinct versions" do
    igniter =
      [
        files: %{
          "lib/test/repo.ex" =>
            "defmodule Test.Repo do\n  use Ecto.Repo, otp_app: :test, adapter: Ecto.Adapters.Postgres\nend\n"
        }
      ]
      |> test_project()
      |> Igniter.compose_task("phoenix_flags.upgrade", ["0.4.0", "0.10.1"])

    migrations =
      igniter.rewrite
      |> Rewrite.sources()
      |> Enum.map(& &1.path)
      |> Enum.filter(&String.contains?(&1, "_upgrade_system_flags_v"))
      |> Enum.sort()

    assert [v2, v3, v4] = migrations
    assert v2 =~ "_upgrade_system_flags_v2.exs"
    assert v3 =~ "_upgrade_system_flags_v3.exs"
    assert v4 =~ "_upgrade_system_flags_v4.exs"

    versions = Enum.map(migrations, &(&1 |> Path.basename() |> String.split("_") |> hd()))
    assert versions == Enum.uniq(versions)
  end
end
