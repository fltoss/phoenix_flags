defmodule PhoenixFlags.TestSelectConfig do
  @moduledoc false
  use PhoenixFlags,
    otp_app: :phoenix_flags,
    repo: PhoenixFlags.TestRepo

  flag("email_provider",
    type: :select,
    default: "mailjet",
    category: "email",
    label: "Email Provider",
    options: [{"Mailjet", "mailjet"}, {"SES", "ses"}]
  )
end
