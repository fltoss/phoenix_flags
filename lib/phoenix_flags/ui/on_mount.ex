if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule PhoenixFlags.UI.OnMount do
    @moduledoc """
    LiveView on_mount hook that injects the PhoenixFlags config module.

    Use this when mounting the dashboard inside your app's existing `live_session`:

        # Simple — just the config module
        live_session :admin,
          on_mount: [
            {PhoenixFlags.UI.OnMount, MyApp.SystemConfig},
            ...
          ] do
          ...
        end

        # With layout component wrapper (for apps that use explicit layout components)
        live_session :admin,
          on_mount: [
            {PhoenixFlags.UI.OnMount, config: MyApp.SystemConfig, layout_component: {MyAppWeb.Layouts, :app}},
            ...
          ] do
          ...
        end
    """
    import Phoenix.Component

    def on_mount(config_module, _params, _session, socket) when is_atom(config_module) do
      {:cont, assign(socket, :phoenix_flags_config, config_module)}
    end

    def on_mount(opts, _params, _session, socket) when is_list(opts) do
      config_module = Keyword.fetch!(opts, :config)
      layout_component = Keyword.get(opts, :layout_component)

      socket =
        socket
        |> assign(:phoenix_flags_config, config_module)
        |> assign(:phoenix_flags_layout_component, layout_component)

      {:cont, socket}
    end
  end
end
