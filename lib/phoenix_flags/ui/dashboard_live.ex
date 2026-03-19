if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule PhoenixFlags.UI.DashboardLive do
    @moduledoc false
    use Phoenix.LiveView

    import PhoenixFlags.UI.Components

    alias PhoenixFlags.Entry

    @impl true
    def mount(_params, session, socket) do
      config_module =
        socket.assigns[:phoenix_flags_config] || session["config"] ||
          raise PhoenixFlags.Error,
                "no config module found. Use {PhoenixFlags.UI.OnMount, MyApp.SystemConfig} in on_mount or the flags_dashboard router macro."

      layout = session["layout"]
      grouped = config_module.all_grouped()

      socket =
        socket
        |> assign(:page_title, "System Flags")
        |> assign(:config_module, config_module)
        |> assign(:grouped_configs, grouped)
        |> assign(:forms, build_forms(grouped))
        |> assign(:editing_key, nil)

      if layout do
        {:ok, socket, layout: layout}
      else
        {:ok, socket}
      end
    end

    @impl true
    def handle_event("pf-edit", %{"key" => key}, socket) do
      {:noreply, assign(socket, :editing_key, key)}
    end

    @impl true
    def handle_event("pf-cancel", _params, socket) do
      {:noreply,
       socket
       |> assign(:forms, build_forms(socket.assigns.grouped_configs))
       |> assign(:editing_key, nil)}
    end

    @impl true
    def handle_event("pf-toggle", %{"key" => key}, socket) do
      config = socket.assigns.config_module
      current = config.get(key)
      new_value = if current, do: "false", else: "true"

      case config.update_entry(key, %{"value" => new_value}) do
        {:ok, _entry} ->
          grouped = config.all_grouped()

          {:noreply,
           socket
           |> assign(:grouped_configs, grouped)
           |> assign(:forms, build_forms(grouped))
           |> put_flash(:info, "Flag updated")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to update flag")}
      end
    end

    @impl true
    def handle_event("pf-save", %{"key" => key, "entry" => entry_params}, socket) do
      config = socket.assigns.config_module

      case config.update_entry(key, entry_params) do
        {:ok, _entry} ->
          grouped = config.all_grouped()

          {:noreply,
           socket
           |> assign(:grouped_configs, grouped)
           |> assign(:forms, build_forms(grouped))
           |> assign(:editing_key, nil)
           |> put_flash(:info, "Flag updated")}

        {:error, changeset} ->
          forms = Map.put(socket.assigns.forms, key, to_form(changeset, as: :entry))
          {:noreply, assign(socket, :forms, forms)}
      end
    end

    @impl true
    def render(assigns) do
      ~H"""
      <div class="space-y-6">
        <div>
          <h1 class="text-2xl font-bold text-base-content">System Flags</h1>
          <p class="text-sm text-base-content/60 mt-1">
            Global settings that apply across the platform. Changes take effect immediately.
          </p>
        </div>

        <div :if={@grouped_configs == []} class="text-center py-12 text-base-content/50">
          No flags configured.
        </div>

        <div class="space-y-6">
          <div :for={{category, entries} <- @grouped_configs} class="card bg-base-100 border border-base-300">
            <div class="px-6 py-4 border-b border-base-300">
              <h2 class="text-xs font-semibold text-base-content/50 uppercase tracking-wider">
                {category_label(category)}
              </h2>
            </div>

            <div class="divide-y divide-base-200">
              <.config_row
                :for={entry <- entries}
                entry={entry}
                form={@forms[entry.key]}
                editing={@editing_key == entry.key}
                select_options={@config_module.select_options(entry.key)}
              />
            </div>
          </div>
        </div>
      </div>
      """
    end

    defp category_label(category) do
      category
      |> String.replace("_", " ")
      |> String.split(" ")
      |> Enum.map_join(" ", &String.capitalize/1)
    end

    defp build_forms(grouped) do
      grouped
      |> Enum.flat_map(fn {_category, entries} -> entries end)
      |> Map.new(fn entry ->
        {entry.key, to_form(Entry.changeset(entry, %{}), as: :entry)}
      end)
    end
  end
end
