defmodule PhoenixFlags.TestRepo.Migrations.AddSystemFlags do
  use Ecto.Migration

  def up, do: PhoenixFlags.Migration.up()
  def down, do: PhoenixFlags.Migration.down(version: 1)
end
