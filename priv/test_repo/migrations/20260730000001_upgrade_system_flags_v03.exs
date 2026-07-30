defmodule PhoenixFlags.TestRepo.Migrations.UpgradeSystemFlagsV03 do
  use Ecto.Migration

  def up, do: PhoenixFlags.Migration.up(version: 3)
  def down, do: PhoenixFlags.Migration.down(version: 3)
end
