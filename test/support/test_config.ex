defmodule PhoenixFlags.TestConfig do
  @moduledoc false
  use PhoenixFlags,
    otp_app: :phoenix_flags,
    repo: PhoenixFlags.TestRepo

  flag "enable_benefits",
    type: :boolean,
    default: "false",
    category: "test",
    label: "Enable Benefits"

  def benefits_enabled?, do: get("enable_benefits", false)
end
