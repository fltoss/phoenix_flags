defmodule PhoenixFlags.Migration.V02 do
  @moduledoc false

  use Ecto.Migration

  def up(%{prefix: prefix}) do
    create table(:system_flags_audit, primary_key: false, prefix: prefix) do
      add(:id, :binary_id, primary_key: true)
      add(:key, :string, null: false)
      add(:old_value, :string)
      add(:new_value, :string)
      add(:actor, :string)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create(index(:system_flags_audit, [:key], prefix: prefix))
    create(index(:system_flags_audit, [:inserted_at], prefix: prefix))
  end

  def down(%{prefix: prefix}) do
    drop_if_exists(table(:system_flags_audit, prefix: prefix))
  end
end
