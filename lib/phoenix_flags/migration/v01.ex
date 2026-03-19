defmodule PhoenixFlags.Migration.V01 do
  @moduledoc false

  use Ecto.Migration

  def up(%{prefix: prefix}) do
    create table(:system_flags, primary_key: false, prefix: prefix) do
      add(:id, :binary_id, primary_key: true)
      add(:key, :string, null: false)
      add(:value, :string)
      add(:type, :string, null: false, default: "string")
      add(:category, :string, null: false)
      add(:label, :string, null: false)
      add(:description, :string)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:system_flags, [:key], prefix: prefix))
  end

  def down(%{prefix: prefix}) do
    drop_if_exists(table(:system_flags, prefix: prefix))
  end
end
