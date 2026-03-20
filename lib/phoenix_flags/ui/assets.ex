if Code.ensure_loaded?(Plug) do
  defmodule PhoenixFlags.UI.Assets do
    @moduledoc false

    @behaviour Plug

    @css_content File.read!(Path.join(:code.priv_dir(:phoenix_flags), "static/app.css"))
    @css_hash :crypto.hash(:md5, @css_content) |> Base.url_encode64(padding: false)

    @spec current_hash(:css) :: String.t()
    def current_hash(:css), do: @css_hash

    @impl Plug
    def init(action), do: action

    @impl Plug
    def call(conn, _action) do
      hash = conn.params["hash"]

      if hash == @css_hash do
        conn
        |> Plug.Conn.put_resp_header("content-type", "text/css; charset=utf-8")
        |> Plug.Conn.put_resp_header(
          "cache-control",
          "public, max-age=31536000, immutable"
        )
        |> Plug.Conn.send_resp(200, @css_content)
        |> Plug.Conn.halt()
      else
        conn
        |> Plug.Conn.send_resp(404, "not found")
        |> Plug.Conn.halt()
      end
    end
  end
end
