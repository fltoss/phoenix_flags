defmodule PhoenixFlags.TestRepo.Migrations.UpgradeSystemFlagsV02 do
  use Ecto.Migration

  def up, do: PhoenixFlags.Migration.up(version: 2)
  def down, do: PhoenixFlags.Migration.down(version: 2)
end
