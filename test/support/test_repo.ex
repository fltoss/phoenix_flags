defmodule PhoenixFlags.TestRepo do
  @moduledoc false
  use Ecto.Repo,
    otp_app: :phoenix_flags,
    adapter: Ecto.Adapters.Postgres
end
