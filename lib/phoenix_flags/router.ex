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
      * `:app_js` — path to the host application's JS bundle, which must connect
        a LiveSocket. Defaults to `"/assets/js/app.js"`.
      * `:favicon` — href for the dashboard's icon. Defaults to `"data:,"`,
        an empty document, which stops the browser asking: a layout with no icon
        makes it request `/favicon.ico`, and a host that does not serve one gets
        a 404 in the console of an otherwise working page. Point it at your own
        to show it instead.
      * `:app_js_type` — the script tag's `type`. Pass `"module"` when the host
        bundle is ESM, which esbuild emits with `--format=esm` and which any
        bundle using `import()` for code splitting needs. Omitted by default,
        so a classic bundle is loaded as it always was.

        Getting this wrong is quiet and total: an ESM bundle loaded as a classic
        script throws `import declarations may only appear at top level of a
        module` before it defines anything, so the LiveSocket never connects and
        every control on the dashboard does nothing at all.
    """

    @doc """
    Defines routes for the PhoenixFlags dashboard.
    """
    defmacro flags_dashboard(path, opts) do
      quote bind_quoted: binding() do
        {session_name, pipeline_name, session_opts, route_opts, app_js, app_js_type, favicon} =
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
            plug(:phoenix_flags_assign_app_js, {app_js, app_js_type, favicon})
          end

          pipe_through(pipeline_name)

          live_session session_name, session_opts do
            live("/", PhoenixFlags.UI.DashboardLive, :index, route_opts)
          end
        end

        unless Module.defines?(__MODULE__, {:phoenix_flags_assign_app_js, 2}) do
          @doc false
          def phoenix_flags_assign_app_js(conn, {app_js, app_js_type, favicon}) do
            conn
            |> Plug.Conn.assign(:app_js, app_js)
            |> Plug.Conn.assign(:app_js_type, app_js_type)
            |> Plug.Conn.assign(:favicon, favicon)
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
      app_js_type = Keyword.get(options, :app_js_type)
      favicon = Keyword.get(options, :favicon, "data:,")

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

      {session_name, pipeline_name, session_opts, route_opts, app_js, app_js_type, favicon}
    end

    @doc false
    def __session__(_conn, config) do
      %{"config" => config}
    end
  end
end
