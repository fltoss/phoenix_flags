defmodule PhoenixFlags.AuditLog do
  @moduledoc """
  Schema for flag change audit records.

  Each row represents a single value change to a flag, recording who changed
  it, what the old and new values were, and when it happened.

  Audit logging is opt-in — enable it with `audit: true` in your config module:

      use PhoenixFlags,
        otp_app: :my_app,
        repo: MyApp.Repo,
        audit: true,
        actor_fn: &MyApp.Flags.current_user/1
  """

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "system_flags_audit" do
    field(:key, :string)
    field(:old_value, :string)
    field(:new_value, :string)
    field(:actor, :string)

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
