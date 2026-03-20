if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule PhoenixFlags.UI.OnMount do
    @moduledoc """
    LiveView on_mount hook that injects the PhoenixFlags config module.

    Use this when mounting the dashboard inside your app's existing `live_session`:

        live_session :admin,
          on_mount: [
            {PhoenixFlags.UI.OnMount, MyApp.SystemConfig},
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
      {:cont, assign(socket, :phoenix_flags_config, config_module)}
    end
  end
end
