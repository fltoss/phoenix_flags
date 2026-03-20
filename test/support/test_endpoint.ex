defmodule PhoenixFlags.TestEndpoint do
  @moduledoc false
  use Phoenix.Endpoint, otp_app: :phoenix_flags

  @session_options [
    store: :cookie,
    key: "_pf_test_key",
    signing_salt: "pf_test_salt",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]
  )

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(Plug.Session, @session_options)
  plug(PhoenixFlags.TestRouter)
end
