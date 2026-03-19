defmodule PhoenixFlags.TestRepo do
  use Ecto.Repo,
    otp_app: :phoenix_flags,
    adapter: Ecto.Adapters.Postgres
end
