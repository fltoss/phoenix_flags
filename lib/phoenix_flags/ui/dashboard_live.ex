if Code.ensure_loaded?(Phoenix.LiveView) do
  defmodule PhoenixFlags.UI.DashboardLive do
    @moduledoc false
    use Phoenix.LiveView

    import PhoenixFlags.UI.Components

    alias PhoenixFlags.Entry

    require Logger

    # Another admin, or another node, can change a flag while this page is open.
    # Reading the cache is a :persistent_term lookup, so a short interval is free.
    @refresh_interval 5_000

    @impl true
    def mount(_params, session, socket) do
      config_module =
        socket.assigns[:phoenix_flags_config] || session["config"] ||
          raise PhoenixFlags.Error,
                "no config module found. Use {PhoenixFlags.UI.OnMount, MyApp.SystemConfig} in on_mount or the flags_dashboard router macro."

      if connected?(socket), do: schedule_refresh()

      {:ok,
       socket
       |> assign(:page_title, "PhoenixFlags")
       |> assign(:config_module, config_module)
       |> assign(:declared_keys, MapSet.new(config_module.flags(), & &1.key))
       |> assign(:actor, resolve_actor(config_module, socket))
       |> assign(:editing_key, nil)
       |> assign(:targets, [])
       |> assign(:target_error, nil)
       |> assign(:notice, nil)
       |> assign(:forms, %{})
       |> reload()}
    end

    @impl true
    def handle_info(:pf_refresh, socket) do
      schedule_refresh()
      {:noreply, reload(socket)}
    end

    @impl true
    def handle_event("pf-edit", %{"key" => key}, socket) do
      case find_entry(socket, key) do
        %Entry{} ->
          {:noreply,
           socket
           |> assign(editing_key: key, target_error: nil, notice: nil)
           |> assign(:targets, socket.assigns.config_module.targets(key))
           |> reload()}

        nil ->
          {:noreply, socket}
      end
    end

    def handle_event("pf-cancel", _params, socket), do: {:noreply, close(socket)}

    def handle_event("pf-dismiss-notice", _params, socket),
      do: {:noreply, assign(socket, :notice, nil)}

    def handle_event(
          "pf-add-target",
          %{"key" => key, "target" => params},
          %{assigns: %{editing_key: key}} = socket
        ) do
      %{config_module: config, actor: actor} = socket.assigns

      case config.put_target(key, target_attrs(params), actor: actor) do
        {:ok, _target} ->
          {:noreply, rules_changed(socket)}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :target_error, target_error_message(changeset))}

        {:error, reason} ->
          {:noreply,
           assign(socket, :target_error, failure_message(reason, "The rule was not added."))}
      end
    end

    # Only a rule on the flag being edited, as listed: a forged id must not
    # reach a rule on some other flag.
    def handle_event("pf-delete-target", %{"target-id" => target_id}, socket) do
      %{config_module: config, actor: actor, targets: targets} = socket.assigns

      if Enum.any?(targets, &(&1.id == target_id)) do
        case config.delete_target(target_id, actor: actor) do
          {:ok, _deleted} ->
            {:noreply, rules_changed(socket)}

          {:error, reason} ->
            {:noreply,
             assign(socket, :target_error, failure_message(reason, "The rule was not deleted."))}
        end
      else
        {:noreply, socket}
      end
    end

    # The key arrives from client event params, so only a flag that renders a
    # toggle can be toggled: a forged event could otherwise write "true" over a
    # flag of another type.
    def handle_event("pf-toggle", %{"key" => key}, socket) do
      case find_entry(socket, key) do
        %Entry{type: "boolean"} = entry ->
          new_value = if entry.value == "true", do: "false", else: "true"
          {:noreply, socket |> save(key, %{"value" => new_value}) |> reload()}

        _other ->
          {:noreply, socket}
      end
    end

    def handle_event("pf-validate", %{"key" => key, "entry" => params}, socket)
        when is_map(params) do
      # Re-render the editor with the submitted weights so the running total and
      # any error show up as the operator types. No write.
      case find_entry(socket, key) do
        %Entry{} = entry ->
          changeset =
            entry
            |> Entry.changeset(variant_attrs(socket, key, params),
              variants: variant_names(socket, key)
            )
            |> Map.put(:action, :validate)

          {:noreply, put_form(socket, key, changeset)}

        nil ->
          {:noreply, socket}
      end
    end

    def handle_event("pf-save", %{"key" => key, "entry" => params}, socket) when is_map(params) do
      # A secret is posted as "password", which Phoenix's default
      # :filter_parameters keeps out of LiveView's debug log of the event.
      secret = Map.get(params, "password")

      case find_entry(socket, key) do
        # A blank secret keeps the stored one; Clear is how it is emptied.
        %Entry{type: "secret"} when secret in [nil, ""] ->
          {:noreply, socket |> close() |> assign(:notice, {:info, "Kept the stored secret."})}

        %Entry{type: "secret"} when is_binary(secret) ->
          {:noreply, save(socket, key, %{"value" => secret})}

        %Entry{} ->
          {:noreply, save(socket, key, variant_attrs(socket, key, params))}

        nil ->
          {:noreply, socket}
      end
    end

    def handle_event("pf-clear-secret", %{"key" => key}, socket) do
      case find_entry(socket, key) do
        %Entry{type: "secret"} -> {:noreply, save(socket, key, %{"value" => ""})}
        _other -> {:noreply, socket}
      end
    end

    # Events and their shapes are client-controlled, so an unknown name or a
    # missing field must not crash the view for want of a matching clause.
    def handle_event(event, _params, socket) do
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

      <.notice notice={@notice} />

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
              declared={MapSet.member?(@declared_keys, entry.key)}
              select_options={@config_module.select_options(entry.key)}
              variants={@config_module.variants(entry.key)}
            />
          </div>
        </div>
      </div>

      <.edit_modal
        :if={@editing}
        entry={@editing}
        form={@forms[@editing_key]}
        select_options={@config_module.select_options(@editing_key)}
        variants={@config_module.variants(@editing_key)}
        targets={@targets}
        target_error={@target_error}
      />
      """
    end

    # Saves, then closes the dialog -- or keeps it open with the changeset's
    # errors, or says what went wrong. Every outcome reloads, because a
    # timed-out write may still have landed.
    defp save(socket, key, attrs) do
      %{config_module: config, actor: actor} = socket.assigns

      case config.update_entry(key, attrs, actor: actor) do
        {:ok, _entry} ->
          close(socket)

        {:error, %Ecto.Changeset{} = changeset} ->
          socket
          |> put_form(key, changeset)
          |> assign(
            :notice,
            if(socket.assigns.editing_key != key, do: {:error, changeset_message(changeset)})
          )

        {:error, reason} ->
          Logger.warning(
            "PhoenixFlags: dashboard could not save #{inspect(key)}: #{inspect(reason)}"
          )

          socket
          |> close()
          |> assign(:notice, {:error, failure_message(reason, "Nothing was saved.")})
      end
    end

    defp close(socket) do
      socket
      |> assign(editing_key: nil, targets: [], target_error: nil)
      |> reload()
    end

    # A rule change reloads the rows but keeps the form being edited: the
    # operator's unsaved weights must survive adding a rule.
    defp rules_changed(socket) do
      key = socket.assigns.editing_key

      socket
      |> assign(:target_error, nil)
      |> assign(:targets, socket.assigns.config_module.targets(key))
      |> reload()
    end

    # The rows from the cache, the dialog's entry derived from them -- so a
    # reload cannot leave it showing a stale value -- and a fresh form for every
    # flag but the one being edited.
    defp reload(socket) do
      grouped = socket.assigns.config_module.all_grouped()
      editing_key = socket.assigns.editing_key
      editing = editing_key && find_in(grouped, editing_key)

      forms =
        grouped
        |> build_forms()
        |> Map.merge(Map.take(socket.assigns.forms, List.wrap(editing && editing_key)))

      assign(socket,
        grouped_configs: grouped,
        editing: editing,
        editing_key: editing && editing_key,
        forms: forms
      )
    end

    defp put_form(socket, key, changeset) do
      assign(socket, :forms, Map.put(socket.assigns.forms, key, to_form(changeset, as: :entry)))
    end

    defp schedule_refresh, do: Process.send_after(self(), :pf_refresh, @refresh_interval)

    defp failure_message(:timeout, _outcome),
      do:
        "The save is taking longer than expected and may still land. Showing what is stored now."

    defp failure_message(:unavailable, outcome),
      do: "The flags server is not available. #{outcome}"

    defp failure_message(:not_found, outcome), do: "That no longer exists. #{outcome}"
    defp failure_message(_reason, outcome), do: "Something went wrong. #{outcome}"

    defp changeset_message(changeset) do
      case changeset.errors[:value] do
        {message, _opts} -> "Not saved: #{message}."
        nil -> "Not saved."
      end
    end

    # The add-rule form posts one condition, comma separated values. Rules with
    # several conditions are created through put_target/3 and render here fine.
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

    defp find_entry(socket, key), do: find_in(socket.assigns.grouped_configs, key)

    defp find_in(grouped, key) do
      Enum.find_value(grouped, fn {_category, entries} -> Enum.find(entries, &(&1.key == key)) end)
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

    # A forged payload can put a map or list where a number belongs, and
    # interpolating one raises inside the LiveView. Anything that is not a plain
    # string becomes "0", which then fails the total check as a field error.
    defp weight_param(submitted, name) do
      case Map.get(submitted, name) do
        value when is_binary(value) -> value
        _other -> "0"
      end
    end

    defp variant_names(socket, key) do
      Enum.map(socket.assigns.config_module.variants(key), fn {_label, name, _weight} -> name end)
    end

    defp category_label(category) do
      category
      |> String.replace("_", " ")
      |> String.split(" ")
      |> Enum.map_join(" ", &String.capitalize/1)
    end

    defp build_forms(grouped) do
      for {_category, entries} <- grouped, entry <- entries, into: %{} do
        {entry.key, to_form(Entry.changeset(entry, %{}), as: :entry)}
      end
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
