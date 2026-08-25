if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule PhoenixFlags.UI.DashboardLive do
    @moduledoc false
    use Phoenix.LiveView

    import PhoenixFlags.UI.Components

    alias PhoenixFlags.Entry

    require Logger

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
       |> assign(:editing_key, nil)
       |> assign(:targets, [])
       |> assign(:target_error, nil)}
    end

    @impl true
    def handle_event("pf-edit", %{"key" => key}, socket) do
      {:noreply,
       socket
       |> assign(:editing_key, key)
       |> assign(:target_error, nil)
       |> load_targets(key)}
    end

    @impl true
    def handle_event("pf-cancel", _params, socket) do
      {:noreply,
       socket
       |> assign(:forms, build_forms(socket.assigns.grouped_configs))
       |> assign(:editing_key, nil)
       |> assign(:target_error, nil)
       |> assign(:targets, [])}
    end

    @impl true
    def handle_event("pf-add-target", %{"key" => key, "target" => params}, socket) do
      config = socket.assigns.config_module

      case config.put_target(key, target_attrs(params)) do
        {:ok, _target} ->
          {:noreply,
           socket
           |> assign(:target_error, nil)
           |> load_targets(key)
           |> reload()}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :target_error, target_error_message(changeset))}

        {:error, reason} ->
          {:noreply, assign(socket, :target_error, "could not add rule: #{inspect(reason)}")}
      end
    end

    @impl true
    def handle_event("pf-delete-target", %{"target-id" => target_id}, socket) do
      config = socket.assigns.config_module
      key = socket.assigns.editing_key

      case config.delete_target(target_id) do
        {:ok, _deleted} ->
          {:noreply, socket |> assign(:target_error, nil) |> load_targets(key) |> reload()}

        {:error, _reason} ->
          {:noreply, assign(socket, :target_error, "that rule no longer exists")}
      end
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

        {:error, %Ecto.Changeset{} = changeset} ->
          forms = Map.put(socket.assigns.forms, key, to_form(changeset, as: :entry))
          {:noreply, assign(socket, :forms, forms)}

        {:error, reason} ->
          # A forged event can name a key that is not in the table, and
          # update_entry/4 then returns {:error, :not_found} — not a changeset,
          # and to_form/2 raises on it. Leave edit mode rather than taking the
          # dashboard down.
          Logger.warning(
            "PhoenixFlags: dashboard could not save #{inspect(key)}: #{inspect(reason)}"
          )

          {:noreply, assign(socket, :editing_key, nil)}
      end
    end

    @impl true
    def handle_event(event, _params, socket) do
      # Events and their shapes are client-controlled, so an unknown name or a
      # missing field must not crash the view for want of a matching clause.
      Logger.warning("PhoenixFlags: dashboard ignoring unexpected event #{inspect(event)}")

      {:noreply, socket}
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
              select_options={@config_module.select_options(entry.key)}
              variants={@config_module.variants(entry.key)}
            />
          </div>
        </div>
      </div>

      <.edit_modal
        :if={editing_entry(@grouped_configs, @editing_key)}
        entry={editing_entry(@grouped_configs, @editing_key)}
        form={@forms[@editing_key]}
        select_options={@config_module.select_options(@editing_key)}
        variants={@config_module.variants(@editing_key)}
        targets={@targets}
        target_error={@target_error}
      />
      """
    end

    defp load_targets(socket, key) when is_binary(key) do
      assign(socket, :targets, socket.assigns.config_module.targets(key))
    end

    defp load_targets(socket, _key), do: assign(socket, :targets, [])

    # The add-rule form posts one condition, comma separated values. Rules with
    # several conditions are created through put_target/2 and render here fine.
    defp target_attrs(params) when is_map(params) do
      values =
        params
        |> param_string("values")
        |> String.split(",")
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == ""))

      [
        value: param_string(params, "value"),
        conditions: [
          [
            attribute: params |> param_string("attribute") |> String.trim(),
            operator: param_string(params, "operator", "in"),
            values: values
          ]
        ]
      ]
    end

    defp target_attrs(_params), do: [value: "", conditions: []]

    # Params are client-controlled, so a forged payload can put a map or list
    # where a string belongs -- and to_string/1 raises on those, taking the
    # LiveView down. Anything that is not already a string becomes the fallback,
    # which then fails validation as an ordinary error.
    defp param_string(params, field, fallback \\ "") do
      case Map.get(params, field) do
        value when is_binary(value) -> value
        _other -> fallback
      end
    end

    # Errors can land on the rule or on a nested condition; surface whichever
    # the operator actually needs to see rather than a bare "is invalid".
    defp target_error_message(changeset) do
      changeset
      |> Ecto.Changeset.traverse_errors(fn {message, _opts} -> message end)
      |> flatten_errors()
      |> case do
        [] -> "could not add rule"
        messages -> Enum.join(messages, "; ")
      end
    end

    defp flatten_errors(errors) when is_map(errors) do
      Enum.flat_map(errors, fn {field, value} ->
        Enum.map(flatten_errors(value), &"#{field} #{&1}")
      end)
    end

    defp flatten_errors(errors) when is_list(errors) do
      Enum.flat_map(errors, fn
        error when is_binary(error) -> [error]
        error -> flatten_errors(error)
      end)
    end

    defp flatten_errors(error) when is_binary(error), do: [error]
    defp flatten_errors(_error), do: []

    # Derived from grouped_configs rather than held in its own assign, so a
    # reload cannot leave the dialog showing a stale entry.
    defp editing_entry(_grouped, nil), do: nil

    defp editing_entry(grouped, key) do
      grouped
      |> Enum.flat_map(fn {_category, entries} -> entries end)
      |> Enum.find(&(&1.key == key))
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
              "#{name}=#{weight_param(submitted, name)}"
            end)

          params |> Map.delete("variants") |> Map.put("value", value)
      end
    end

    defp variant_attrs(_socket, _key, params), do: params

    # Params are client-controlled, so a forged payload can put a map or list
    # where a number belongs — and interpolating one raises
    # Protocol.UndefinedError inside the LiveView. Anything that is not a plain
    # string becomes "0", which then fails the total check and surfaces as an
    # ordinary field error.
    defp weight_param(submitted, name) do
      case Map.get(submitted, name) do
        value when is_binary(value) -> value
        _other -> "0"
      end
    end

    defp variant_names(socket, key) do
      socket.assigns.config_module.variants(key)
      |> Enum.map(fn {_label, name, _weight} -> name end)
    end

    defp find_entry(socket, key), do: editing_entry(socket.assigns.grouped_configs, key)

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
