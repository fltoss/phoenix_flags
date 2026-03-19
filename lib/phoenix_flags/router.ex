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
              layout: {MyAppWeb.Layouts, :app}
          end
        end

    ## Options

      * `:config` (required) — the module that `use PhoenixFlags`
      * `:layout` — the inner layout to wrap the dashboard, e.g. `{MyAppWeb.Layouts, :app}`.
        This is passed to the LiveView at mount time so the dashboard renders inside
        your app's sidebar/nav. The root layout (HTML shell with CSS) comes from
        your endpoint's default.
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

          live_session session_name, session_opts do
            live "/", PhoenixFlags.UI.DashboardLive, :index, route_opts
          end
        end
      end
    end

    @doc false
    def __options__(options) do
      config = Keyword.fetch!(options, :config)
      layout = Keyword.get(options, :layout)
      on_mount = Keyword.get(options, :on_mount, [])
      live_socket_path = Keyword.get(options, :live_socket_path, "/live")

      session_opts = [
        on_mount: on_mount,
        session: {__MODULE__, :__session__, [config, layout]}
      ]

      route_opts = [
        private: %{live_socket_path: live_socket_path}
      ]

      session_name = :"phoenix_flags_#{config}"

      {session_name, session_opts, route_opts}
    end

    @doc false
    def __session__(_conn, config, layout) do
      session = %{"config" => config}

      if layout do
        Map.put(session, "layout", layout)
      else
        session
      end
    end
  end
end
