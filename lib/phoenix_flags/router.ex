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
        {session_name, pipeline_name, session_opts, route_opts, app_js} =
          PhoenixFlags.Router.__options__(opts)

        scope path, alias: false, as: false do
          import Phoenix.LiveView.Router, only: [live: 4, live_session: 3]
          import Phoenix.Router, only: [match: 5, pipeline: 2, pipe_through: 1, plug: 2]

          # Serve the self-contained CSS asset
          match(:get, "/css-:hash", PhoenixFlags.UI.Assets, :css, [])

          # The pipeline name must be unique per mounted dashboard: pipelines
          # are plain router functions, so a second `flags_dashboard` call
          # with a shared name would add a dead duplicate clause and silently
          # reuse the first mount's :app_js.
          pipeline pipeline_name do
            plug(:phoenix_flags_assign_app_js, app_js)
          end

          pipe_through(pipeline_name)

          live_session session_name, session_opts do
            live("/", PhoenixFlags.UI.DashboardLive, :index, route_opts)
          end
        end

        unless Module.defines?(__MODULE__, {:phoenix_flags_assign_app_js, 2}) do
          @doc false
          def phoenix_flags_assign_app_js(conn, app_js) do
            Plug.Conn.assign(conn, :app_js, app_js)
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
        session: {__MODULE__, :__session__, [config]}
      ]

      route_opts = [
        private: %{live_socket_path: live_socket_path}
      ]

      session_name = :"phoenix_flags_#{config}"
      pipeline_name = :"phoenix_flags_assigns_#{config}"

      {session_name, pipeline_name, session_opts, route_opts, app_js}
    end

    @doc false
    def __session__(_conn, config) do
      %{"config" => config}
    end
  end
end
