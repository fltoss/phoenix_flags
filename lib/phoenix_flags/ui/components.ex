if Code.ensure_loaded?(Phoenix.Component) do
  defmodule PhoenixFlags.UI.Components do
    @moduledoc false
    use Phoenix.Component

    attr :entry, :map, required: true
    attr :form, :map, required: true
    attr :editing, :boolean, required: true
    attr :select_options, :list, default: []

    def config_row(%{entry: %{type: "boolean"}} = assigns) do
      ~H"""
      <div class="px-6 py-5 flex items-center justify-between">
        <div class="flex-1 pr-8">
          <p class="text-sm font-medium text-base-content">{@entry.label}</p>
          <p :if={@entry.description} class="text-xs text-base-content/60 mt-0.5 max-w-lg">
            {@entry.description}
          </p>
        </div>
        <div class="flex items-center gap-3">
          <button
            type="button"
            phx-click="pf-toggle"
            phx-value-key={@entry.key}
            class={[
              "relative inline-flex h-6 w-11 flex-shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200 ease-in-out focus:outline-none focus:ring-2 focus:ring-primary focus:ring-offset-2",
              if(@entry.value == "true", do: "bg-success", else: "bg-base-300")
            ]}
            role="switch"
            aria-checked={@entry.value == "true"}
          >
            <span class={[
              "pointer-events-none inline-block h-5 w-5 transform rounded-full bg-base-100 shadow ring-0 transition duration-200 ease-in-out",
              if(@entry.value == "true", do: "translate-x-5", else: "translate-x-0")
            ]}>
            </span>
          </button>
          <span class={[
            "text-sm font-medium min-w-[60px]",
            if(@entry.value == "true", do: "text-success", else: "text-base-content/50")
          ]}>
            {if @entry.value == "true", do: "Enabled", else: "Disabled"}
          </span>
        </div>
      </div>
      """
    end

    def config_row(%{editing: false} = assigns) do
      ~H"""
      <div class="px-6 py-5 flex items-center justify-between group">
        <div class="flex-1 pr-8">
          <p class="text-sm font-medium text-base-content">{@entry.label}</p>
          <p :if={@entry.description} class="text-xs text-base-content/60 mt-0.5 max-w-lg">
            {@entry.description}
          </p>
        </div>
        <div class="flex items-center gap-4">
          <span class="text-sm font-semibold text-base-content">{display_value(@entry, @select_options)}</span>
          <button
            phx-click="pf-edit"
            phx-value-key={@entry.key}
            class="text-xs font-medium text-primary opacity-0 group-hover:opacity-100 transition-opacity hover:underline"
          >
            Edit
          </button>
        </div>
      </div>
      """
    end

    def config_row(%{editing: true} = assigns) do
      ~H"""
      <div class="px-6 py-5 bg-base-200/50">
        <form phx-submit="pf-save" phx-value-key={@entry.key}>
          <div class="flex items-start gap-4">
            <div class="flex-1">
              <p class="text-sm font-medium text-base-content mb-1">{@entry.label}</p>
              <p :if={@entry.description} class="text-xs text-base-content/60 mb-3 max-w-lg">
                {@entry.description}
              </p>
              <div class="max-w-xs">
                <.config_input entry={@entry} form={@form} select_options={@select_options} />
              </div>
            </div>
            <div class="flex gap-2 pt-6">
              <button type="submit" class="btn btn-primary btn-sm">Save</button>
              <button type="button" phx-click="pf-cancel" class="btn btn-sm">Cancel</button>
            </div>
          </div>
        </form>
      </div>
      """
    end

    defp config_input(%{entry: %{type: "integer"}} = assigns) do
      ~H"""
      <div>
        <input
          type="number"
          name="entry[value]"
          value={@form[:value].value}
          step="1"
          class={["input input-bordered input-sm w-full", @form[:value].errors != [] && "input-error"]}
        />
        <.field_errors errors={@form[:value].errors} />
      </div>
      """
    end

    defp config_input(%{entry: %{type: type}} = assigns) when type in ["decimal", "percentage"] do
      ~H"""
      <div>
        <input
          type="number"
          name="entry[value]"
          value={@form[:value].value}
          step="0.01"
          class={["input input-bordered input-sm w-full", @form[:value].errors != [] && "input-error"]}
        />
        <.field_errors errors={@form[:value].errors} />
      </div>
      """
    end

    defp config_input(%{entry: %{type: "select"}} = assigns) do
      ~H"""
      <div>
        <select
          name="entry[value]"
          class={["select select-bordered select-sm w-full", @form[:value].errors != [] && "select-error"]}
        >
          <option :for={{label, value} <- @select_options} value={value} selected={value == @form[:value].value}>
            {label}
          </option>
        </select>
        <.field_errors errors={@form[:value].errors} />
      </div>
      """
    end

    defp config_input(assigns) do
      ~H"""
      <div>
        <input
          type="text"
          name="entry[value]"
          value={@form[:value].value}
          class={["input input-bordered input-sm w-full", @form[:value].errors != [] && "input-error"]}
        />
        <.field_errors errors={@form[:value].errors} />
      </div>
      """
    end

    defp field_errors(assigns) do
      ~H"""
      <p :for={{message, _opts} <- @errors} class="text-xs text-error mt-1">{message}</p>
      """
    end

    defp display_value(%{type: "select", value: value}, options) do
      Enum.find_value(options, value, fn {label, val} -> if val == value, do: label end)
    end

    defp display_value(%{type: "percentage", value: value}, _options), do: "#{value}%"
    defp display_value(%{type: "decimal", value: value}, _options), do: value
    defp display_value(%{value: value}, _options), do: value
  end
end
