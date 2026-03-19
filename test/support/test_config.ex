defmodule PhoenixFlags.TestConfig do
  use PhoenixFlags,
    otp_app: :phoenix_flags,
    repo: PhoenixFlags.TestRepo

  def benefits_enabled?, do: get("enable_benefits", false)
end
