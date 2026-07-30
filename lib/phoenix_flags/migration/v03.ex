defmodule PhoenixFlags.Migration.V03 do
  @moduledoc false

  use Ecto.Migration

  # varchar(255) is too small for encrypted :secret values (IV + tag + base64
  # overhead easily exceeds it) and there is no reason to cap flag values.
  #
  # Also moves the schema version out of the system_flags table comment into
  # a queryable system_flags_meta table. The comment is cleared so the two
  # stores cannot drift; Migration.migrated_version/1 still falls back to the
  # comment on databases that haven't run this migration yet.
  def up(%{prefix: prefix}) do
    alter table(:system_flags, prefix: prefix) do
      modify(:value, :text)
    end

    alter table(:system_flags_audit, prefix: prefix) do
      modify(:old_value, :text)
      modify(:new_value, :text)
    end

    create table(:system_flags_meta, primary_key: false, prefix: prefix) do
      add(:key, :string, primary_key: true)
      add(:value, :string)
    end

    execute("COMMENT ON TABLE #{prefix}.system_flags IS NULL")
  end

  # Rolling back can fail if any stored value exceeds 255 characters —
  # PostgreSQL refuses the narrowing cast rather than truncating.
  def down(%{prefix: prefix}) do
    alter table(:system_flags, prefix: prefix) do
      modify(:value, :string)
    end

    alter table(:system_flags_audit, prefix: prefix) do
      modify(:old_value, :string)
      modify(:new_value, :string)
    end

    # set_version/2 restores the version to the table comment afterwards.
    drop_if_exists(table(:system_flags_meta, prefix: prefix))
  end
end
