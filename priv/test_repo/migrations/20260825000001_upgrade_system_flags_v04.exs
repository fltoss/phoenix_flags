defmodule PhoenixFlags.TestRepo.Migrations.UpgradeSystemFlagsV04 do
  use Ecto.Migration

  def up, do: PhoenixFlags.Migration.up(version: 4)
  def down, do: PhoenixFlags.Migration.down(version: 4)
end
