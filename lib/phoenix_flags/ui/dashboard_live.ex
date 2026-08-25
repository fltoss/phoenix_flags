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

      grouped = config_module.all_grouped()
      actor = resolve_actor(config_module, socket)

      {:ok,
       socket
       |> assign(:page_title, "PhoenixFlags")
       |> assign(:config_module, config_module)
       |> assign(:actor, actor)
       |> assign(:grouped_configs, grouped)
       |> assign(:forms, build_forms(grouped))
       |> assign(:editing_key, nil)}
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

      # The key arrives from client event params — only allow toggling flags
      # that actually render a toggle, or a forged event could overwrite a
      # non-boolean flag with "true"/"false".
      case find_entry(socket, key) do
        %Entry{type: "boolean"} = entry ->
          new_value = if entry.value == "true", do: "false", else: "true"

          case config.update_entry(key, %{"value" => new_value}, actor: socket.assigns.actor) do
            {:ok, _entry} ->
              {:noreply, reload(socket)}

            {:error, _changeset} ->
              {:noreply, socket}
          end

        _ ->
          {:noreply, socket}
      end
    end

    @impl true
    def handle_event("pf-validate", %{"key" => key, "entry" => entry_params}, socket) do
      # Re-render the editor with the submitted weights so the running total and
      # any error show up as the operator types. No write.
      case find_entry(socket, key) do
        %Entry{} = entry ->
          changeset =
            entry
            |> Entry.changeset(variant_attrs(socket, key, entry_params),
              variants: variant_names(socket, key)
            )
            |> Map.put(:action, :validate)

          forms = Map.put(socket.assigns.forms, key, to_form(changeset, as: :entry))
          {:noreply, assign(socket, :forms, forms)}

        nil ->
          {:noreply, socket}
      end
    end

    @impl true
    def handle_event("pf-save", %{"key" => key, "entry" => entry_params}, socket) do
      config = socket.assigns.config_module
      entry_params = variant_attrs(socket, key, entry_params)

      case config.update_entry(key, entry_params, actor: socket.assigns.actor) do
        {:ok, _entry} ->
          {:noreply, reload(socket) |> assign(:editing_key, nil)}

        {:error, changeset} ->
          forms = Map.put(socket.assigns.forms, key, to_form(changeset, as: :entry))
          {:noreply, assign(socket, :forms, forms)}
      end
    end

    @impl true
    def render(assigns) do
      ~H"""
      <div class="pf-header">
        <h1>System Flags</h1>
        <p>Global settings. Changes take effect immediately.</p>
      </div>

      <div :if={@grouped_configs == []} class="pf-empty">
        No flags configured.
      </div>

      <div class="pf-cards">
        <div :for={{category, entries} <- @grouped_configs} class="pf-card">
          <div class="pf-card-header">
            <h2>{category_label(category)}</h2>
          </div>

          <div class="pf-card-body">
            <.config_row
              :for={entry <- entries}
              entry={entry}
              form={@forms[entry.key]}
              editing={@editing_key == entry.key}
              select_options={@config_module.select_options(entry.key)}
              variants={@config_module.variants(entry.key)}
            />
          </div>
        </div>
      </div>
      """
    end

    # A variant editor posts one field per variant, so fold them back into the
    # stored "name=weight,..." string. Declared order is used, not the params map
    # order, because bucket order is what makes a rollout sticky.
    defp variant_attrs(socket, key, %{"variants" => submitted} = params) when is_map(submitted) do
      case socket.assigns.config_module.variants(key) do
        [] ->
          params

        declared ->
          value =
            Enum.map_join(declared, ",", fn {_label, name, _weight} ->
              "#{name}=#{Map.get(submitted, name, "0")}"
            end)

          params |> Map.delete("variants") |> Map.put("value", value)
      end
    end

    defp variant_attrs(_socket, _key, params), do: params

    defp variant_names(socket, key) do
      socket.assigns.config_module.variants(key)
      |> Enum.map(fn {_label, name, _weight} -> name end)
    end

    defp find_entry(socket, key) do
      socket.assigns.grouped_configs
      |> Enum.flat_map(fn {_category, entries} -> entries end)
      |> Enum.find(&(&1.key == key))
    end

    defp reload(socket) do
      grouped = socket.assigns.config_module.all_grouped()

      socket
      |> assign(:grouped_configs, grouped)
      |> assign(:forms, build_forms(grouped))
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

    defp resolve_actor(config_module, socket) do
      case PhoenixFlags.Server.config(config_module) do
        %{audit: true, actor_fn: actor_fn} when is_function(actor_fn, 1) ->
          try do
            actor_fn.(socket)
          rescue
            _ -> nil
          end

        _ ->
          nil
      end
    end
  end
end
