if Code.ensure_loaded?(Phoenix.Component) do
  defmodule PhoenixFlags.UI.Layouts do
    @moduledoc false
    use Phoenix.Component

    @doc """
    Full HTML document shell for the PhoenixFlags dashboard.

    Renders a complete `<html>` page with its own CSS — no dependency
    on the consuming application's stylesheets or layouts.
    """
    def root(assigns) do
      assigns = assign_new(assigns, :css_path, fn -> css_path(assigns[:conn]) end)

      ~H"""
      <!DOCTYPE html>
      <html lang="en">
        <head>
          <meta charset="utf-8" />
          <meta name="viewport" content="width=device-width, initial-scale=1" />
          <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
          <title>{assigns[:page_title] || "PhoenixFlags"}</title>
          <%!-- `data:,` by default: with no icon the browser asks for
                `/favicon.ico`, and a host that does not serve one gets a 404 in
                the console of a page that is otherwise working fine. --%>
          <link rel="icon" href={assigns[:favicon] || "data:,"} />
          <link rel="stylesheet" href={@css_path} />
          <%!-- `type` is omitted unless the host says its bundle is ESM. An ESM
                bundle loaded as a classic script throws before it defines
                anything, so the LiveSocket never connects and nothing on this
                page works — see `:app_js_type` in `PhoenixFlags.Router`. --%>
          <script
            type={assigns[:app_js_type]}
            defer
            phx-track-static
            src={assigns[:app_js] || "/assets/js/app.js"}
          >
          </script>
        </head>
        <body class="pf-body">
          {@inner_content}
        </body>
      </html>
      """
    end

    @doc """
    Inner layout for LiveView content.
    """
    def live(assigns) do
      ~H"""
      <div class="pf-container">
        {@inner_content}
      </div>
      """
    end

    defp css_path(%Plug.Conn{} = conn) do
      # The conn's request_path for the LiveView mount will be e.g.
      # "/admin/system/config" — that IS the prefix since the live
      # route is mounted at "/" within the flags_dashboard scope.
      prefix = String.replace_suffix(conn.request_path, "/", "")
      hash = PhoenixFlags.UI.Assets.current_hash(:css)
      "#{prefix}/css-#{hash}"
    end

    defp css_path(_) do
      hash = PhoenixFlags.UI.Assets.current_hash(:css)
      "/css-#{hash}"
    end
  end
end
