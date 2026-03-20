if Code.ensure_loaded?(Phoenix.Component) do
  defmodule PhoenixFlags.UI.Components do
    @moduledoc false
    use Phoenix.Component

    attr(:entry, :map, required: true)
    attr(:form, :map, required: true)
    attr(:editing, :boolean, required: true)
    attr(:select_options, :list, default: [])

    def config_row(%{entry: %{type: "boolean"}} = assigns) do
      ~H"""
      <div class="pf-row">
        <.entry_info entry={@entry} />
        <div class="pf-row-actions">
          <button
            type="button"
            phx-click="pf-toggle"
            phx-value-key={@entry.key}
            class="pf-toggle"
            role="switch"
            aria-checked={to_string(@entry.value == "true")}
          >
            <span class="pf-toggle-knob"></span>
          </button>
          <span class={["pf-toggle-label", if(@entry.value == "true", do: "pf-toggle-label-on", else: "pf-toggle-label-off")]}>
            {if @entry.value == "true", do: "Enabled", else: "Disabled"}
          </span>
        </div>
      </div>
      """
    end

    def config_row(%{editing: false} = assigns) do
      ~H"""
      <div class="pf-row">
        <.entry_info entry={@entry} />
        <div class="pf-row-actions">
          <span class="pf-row-value">{display_value(@entry, @select_options)}</span>
          <button phx-click="pf-edit" phx-value-key={@entry.key} class="pf-row-edit-btn">
            Edit
          </button>
        </div>
      </div>
      """
    end

    def config_row(%{editing: true} = assigns) do
      ~H"""
      <div class="pf-row-editing">
        <form phx-submit="pf-save" phx-value-key={@entry.key}>
          <div class="pf-row-info">
            <.entry_info entry={@entry} />
            <div class="pf-input-wrap">
              <.config_input entry={@entry} form={@form} select_options={@select_options} />
            </div>
          </div>
          <div class="pf-edit-actions">
            <button type="submit" class="pf-btn pf-btn-primary">Save</button>
            <button type="button" phx-click="pf-cancel" class="pf-btn">Cancel</button>
          </div>
        </form>
      </div>
      """
    end

    defp entry_info(assigns) do
      ~H"""
      <div class="pf-row-info">
        <p class="pf-row-label">{@entry.label}</p>
        <p :if={@entry.description} class="pf-row-desc">{@entry.description}</p>
      </div>
      """
    end

    defp config_input(%{entry: %{type: "select"}} = assigns) do
      ~H"""
      <div>
        <select name="entry[value]" class={input_class(@form, "pf-select")}>
          <option :for={{label, value} <- @select_options} value={value} selected={value == @form[:value].value}>
            {label}
          </option>
        </select>
        <.field_errors errors={@form[:value].errors} />
      </div>
      """
    end

    defp config_input(%{entry: %{type: type}} = assigns)
         when type in ["integer", "decimal", "percentage"] do
      assigns = assign(assigns, :step, if(type == "integer", do: "1", else: "0.01"))

      ~H"""
      <div>
        <input type="number" name="entry[value]" value={@form[:value].value} step={@step} class={input_class(@form, "pf-input")} />
        <.field_errors errors={@form[:value].errors} />
      </div>
      """
    end

    defp config_input(assigns) do
      ~H"""
      <div>
        <input type="text" name="entry[value]" value={@form[:value].value} class={input_class(@form, "pf-input")} />
        <.field_errors errors={@form[:value].errors} />
      </div>
      """
    end

    defp field_errors(assigns) do
      ~H"""
      <p :for={{message, _opts} <- @errors} class="pf-field-error">{message}</p>
      """
    end

    defp input_class(form, base) do
      if form[:value].errors != [], do: "#{base} pf-input-error", else: base
    end

    defp display_value(%{type: "select", value: value}, options) do
      Enum.find_value(options, value, fn {label, val} -> if val == value, do: label end)
    end

    defp display_value(%{type: "percentage", value: value}, _options), do: "#{value}%"
    defp display_value(%{value: value}, _options), do: value
  end
end
