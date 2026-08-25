defmodule PhoenixFlags.Migration.V04 do
  @moduledoc false

  use Ecto.Migration

  # Targeting rules: force a flag's value when the request context matches.
  #
  # Conditions live in their own table rather than a jsonb column on the rule.
  # PhoenixFlags declares `jason` as optional and does not use it anywhere in
  # lib/, and the README claims zero external dependencies -- a jsonb column
  # would make a JSON library effectively required. `values` is a native
  # PostgreSQL text[], so there is nothing to serialise either way.
  def up(%{prefix: prefix}) do
    create table(:system_flag_targets, primary_key: false, prefix: prefix) do
      add(:id, :binary_id, primary_key: true)
      add(:key, :string, null: false)
      add(:value, :text, null: false)
      add(:position, :integer, null: false, default: 0)

      timestamps(type: :utc_datetime)
    end

    create(index(:system_flag_targets, [:key], prefix: prefix))

    create table(:system_flag_target_conditions, primary_key: false, prefix: prefix) do
      add(:id, :binary_id, primary_key: true)

      add(
        :target_id,
        references(:system_flag_targets,
          type: :binary_id,
          on_delete: :delete_all,
          prefix: prefix
        ),
        null: false
      )

      add(:attribute, :string, null: false)
      add(:operator, :string, null: false)
      add(:values, {:array, :string}, null: false, default: [])

      timestamps(type: :utc_datetime)
    end

    create(index(:system_flag_target_conditions, [:target_id], prefix: prefix))
  end

  # Conditions are dropped first: the foreign key points at system_flag_targets,
  # and on_delete: :delete_all does not help when dropping the parent table.
  def down(%{prefix: prefix}) do
    drop_if_exists(table(:system_flag_target_conditions, prefix: prefix))
    drop_if_exists(table(:system_flag_targets, prefix: prefix))
  end
end
