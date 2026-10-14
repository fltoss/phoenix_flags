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
              config: MyApp.SystemConfig,
              on_mount: [{MyAppWeb.UserAuth, :require_admin}]
          end

    The dashboard does no authorisation of its own. A pipeline guards the page
    request but not the LiveView's socket: the signed session it hands the
    browser can be replayed to reconnect, after the admin who opened the page
    has lost the role. Always pass an `:on_mount` hook that checks again.
        end

    ## Options

      * `:config` (required) — the module that `use PhoenixFlags`
      * `:on_mount` — list of `Phoenix.LiveView.on_mount/1` hooks to add
        to the live session. This is where authorisation belongs: see above.
      * `:csp_nonce_assign_key` — the conn assign holding your Content Security
        Policy nonce, e.g. `:csp_nonce`. Given, the script tag carries it, so a
        policy with `'strict-dynamic'` or no `'self'` still loads the bundle.
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
        {session_name, pipeline_name, session_opts, page_opts} =
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
            plug(:phoenix_flags_assign_page, page_opts)
          end

          pipe_through(pipeline_name)

          live_session session_name, session_opts do
            live("/", PhoenixFlags.UI.DashboardLive, :index, [])
          end
        end

        unless Module.defines?(__MODULE__, {:phoenix_flags_assign_page, 2}) do
          @doc false

          def phoenix_flags_assign_page(conn, page_opts),
            do: PhoenixFlags.Router.__assign_page__(conn, page_opts)
        end
      end
    end

    @doc false
    def __options__(options) do
      config = Keyword.fetch!(options, :config)

      if Keyword.has_key?(options, :live_socket_path) do
        IO.warn(
          "flags_dashboard's :live_socket_path never had an effect and is deprecated: " <>
            "the socket path is whatever your app.js connects to. Remove the option."
        )
      end

      session_opts = [
        root_layout: {PhoenixFlags.UI.Layouts, :root},
        layout: {PhoenixFlags.UI.Layouts, :live},
        on_mount: Keyword.get(options, :on_mount, []),
        session: {__MODULE__, :__session__, [config]}
      ]

      page_opts = %{
        app_js: Keyword.get(options, :app_js, "/assets/js/app.js"),
        app_js_type: Keyword.get(options, :app_js_type),
        favicon: Keyword.get(options, :favicon, "data:,"),
        csp_nonce_assign_key: Keyword.get(options, :csp_nonce_assign_key)
      }

      {:"phoenix_flags_#{config}", :"phoenix_flags_assigns_#{config}", session_opts, page_opts}
    end

    @doc false

    def __assign_page__(conn, page_opts) do
      nonce = page_opts.csp_nonce_assign_key && conn.assigns[page_opts.csp_nonce_assign_key]

      conn
      |> Plug.Conn.assign(:app_js, page_opts.app_js)
      |> Plug.Conn.assign(:app_js_type, page_opts.app_js_type)
      |> Plug.Conn.assign(:favicon, page_opts.favicon)
      |> Plug.Conn.assign(:phoenix_flags_csp_nonce, nonce)
    end

    @doc false
    def __session__(_conn, config) do
      %{"config" => config}
    end
  end
end
