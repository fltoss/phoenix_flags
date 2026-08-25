defmodule PhoenixFlags.TestVariantConfig do
  @moduledoc false
  use PhoenixFlags,
    otp_app: :phoenix_flags,
    repo: PhoenixFlags.TestRepo

  flag("checkout_flow",
    type: :variant,
    category: "experiments",
    label: "Checkout flow",
    description: "Which checkout to show.",
    variants: [{"Control", "control", 90}, {"New flow", "new_flow", 10}]
  )
end
