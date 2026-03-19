if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule PhoenixFlags.UI.OnMount do
    @moduledoc """
    LiveView on_mount hook that injects the PhoenixFlags config module.

    Use this when mounting the dashboard inside your app's existing `live_session`
    instead of using the `flags_dashboard` router macro:

        live_session :admin,
          on_mount: [
            {PhoenixFlags.UI.OnMount, Moneyclub.SystemConfig},
            ...
          ] do
          live "/system/config", PhoenixFlags.UI.DashboardLive, :index
        end
    """
    import Phoenix.Component

    def on_mount(config_module, _params, _session, socket) do
      {:cont, assign(socket, :phoenix_flags_config, config_module)}
    end
  end
end
