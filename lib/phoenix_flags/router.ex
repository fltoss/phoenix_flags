if Code.ensure_loaded?(Phoenix.LiveView.Router) do
  defmodule PhoenixFlags.Router do
    @moduledoc """
    Provides a router macro for mounting the PhoenixFlags dashboard.

    ## Usage

        defmodule MyAppWeb.Router do
          use Phoenix.Router
          import PhoenixFlags.Router

          scope "/admin" do
            pipe_through [:browser, :require_admin]

            flags_dashboard "/flags",
              config: MyApp.SystemConfig
          end
        end

    ## Options

      * `:config` (required) — the module that `use PhoenixFlags`
      * `:on_mount` — list of `Phoenix.LiveView.on_mount/1` hooks to add
        to the live session (e.g. for authentication)
      * `:live_socket_path` — defaults to `"/live"`
    """

    @doc """
    Defines routes for the PhoenixFlags dashboard.
    """
    defmacro flags_dashboard(path, opts) do
      quote bind_quoted: binding() do
        scope path, alias: false, as: false do
          {session_name, session_opts, route_opts} =
            PhoenixFlags.Router.__options__(opts)

          import Phoenix.LiveView.Router, only: [live: 4, live_session: 3]
          import Phoenix.Router, only: [match: 5]

          # Serve the self-contained CSS asset
          match(:get, "/css-:hash", PhoenixFlags.UI.Assets, :css, [])

          live_session session_name, session_opts do
            live("/", PhoenixFlags.UI.DashboardLive, :index, route_opts)
          end
        end
      end
    end

    @doc false
    def __options__(options) do
      config = Keyword.fetch!(options, :config)
      on_mount = Keyword.get(options, :on_mount, [])
      live_socket_path = Keyword.get(options, :live_socket_path, "/live")
      app_js = Keyword.get(options, :app_js, "/assets/js/app.js")

      session_opts = [
        root_layout: {PhoenixFlags.UI.Layouts, :root},
        layout: {PhoenixFlags.UI.Layouts, :live},
        on_mount: on_mount,
        session: {__MODULE__, :__session__, [config, app_js]}
      ]

      route_opts = [
        private: %{live_socket_path: live_socket_path}
      ]

      session_name = :"phoenix_flags_#{config}"

      {session_name, session_opts, route_opts}
    end

    @doc false
    def __session__(_conn, config, app_js) do
      %{"config" => config, "app_js" => app_js}
    end
  end
end
