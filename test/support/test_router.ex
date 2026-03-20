defmodule PhoenixFlags.TestRouter do
  @moduledoc false
  use Phoenix.Router

  import Phoenix.LiveView.Router
  import PhoenixFlags.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/" do
    pipe_through(:browser)

    flags_dashboard("/flags", config: PhoenixFlags.TestConfig)
  end
end
