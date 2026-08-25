if Code.ensure_loaded?(Phoenix.Component) do
  defmodule PhoenixFlags.UI.Components do
    @moduledoc false
    use Phoenix.Component

    alias Phoenix.LiveView.JS

    attr(:entry, :map, required: true)
    attr(:select_options, :list, default: [])
    attr(:variants, :list, default: [])

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

    def config_row(%{entry: %{type: "secret"}} = assigns) do
      ~H"""
      <div class="pf-row">
        <.entry_info entry={@entry} />
        <div class="pf-row-actions">
          <span class="pf-row-value">{if @entry.value == "", do: "Not set", else: "Set"}</span>
          <button phx-click="pf-edit" phx-value-key={@entry.key} class="pf-row-edit-btn">
            Edit
          </button>
        </div>
      </div>
      """
    end

    def config_row(%{entry: %{type: "variant"}} = assigns) do
      ~H"""
      <div class="pf-row">
        <.entry_info entry={@entry} />
        <div class="pf-row-actions">
          <.variant_bars entry={@entry} variants={@variants} />
          <button phx-click="pf-edit" phx-value-key={@entry.key} class="pf-row-edit-btn">
            Edit
          </button>
        </div>
      </div>
      """
    end

    def config_row(assigns) do
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

    attr(:entry, :map, required: true)
    attr(:form, :map, required: true)
    attr(:select_options, :list, default: [])
    attr(:variants, :list, default: [])
    attr(:targets, :list, default: [])
    attr(:target_error, :string, default: nil)

    @doc """
    The edit dialog. Rendered once by the dashboard for whichever flag is being
    edited, rather than inline in the row.
    """
    def edit_modal(assigns) do
      ~H"""
      <div class="pf-modal-overlay" phx-window-keydown="pf-cancel" phx-key="Escape">
        <div class="pf-modal-backdrop" phx-click="pf-cancel"></div>

        <div
          class="pf-modal"
          role="dialog"
          aria-modal="true"
          aria-labelledby={"pf-modal-title-#{@entry.key}"}
          phx-mounted={JS.focus_first(to: "##{@entry.key |> modal_body_id()}")}
        >
          <div class="pf-modal-header">
            <h3 class="pf-modal-title" id={"pf-modal-title-#{@entry.key}"}>{@entry.label}</h3>
            <button type="button" class="pf-modal-close" phx-click="pf-cancel" aria-label="Close">
              &times;
            </button>
          </div>

          <div class="pf-modal-body" id={modal_body_id(@entry.key)}>
            <p :if={@entry.description} class="pf-modal-desc">{@entry.description}</p>

            <%!-- Two sibling forms: HTML forbids nesting, and the targeting
                  section needs its own submit. --%>
            <form
              id={"pf-form-#{@entry.key}"}
              phx-submit="pf-save"
              phx-change={if @entry.type == "variant", do: "pf-validate"}
              phx-value-key={@entry.key}
            >
              <.config_input
                entry={@entry}
                form={@form}
                select_options={@select_options}
                variants={@variants}
              />
            </form>

            <.targeting_section
              :if={targetable?(@entry)}
              entry={@entry}
              targets={@targets}
              target_error={@target_error}
              variants={@variants}
              select_options={@select_options}
            />
          </div>

          <%!-- The footer sits outside both forms so it stays at the bottom of
                the dialog. `form=` associates the submit button with the value
                form regardless of where it is in the tree, which is how the two
                sibling forms (HTML forbids nesting them) keep one shared
                footer. --%>
          <div class="pf-modal-footer">
            <button type="button" phx-click="pf-cancel" class="pf-btn">Cancel</button>
            <button type="submit" form={"pf-form-#{@entry.key}"} class="pf-btn pf-btn-primary">
              Save
            </button>
          </div>
        </div>
      </div>
      """
    end

    # A :secret flag cannot be targeted -- the rule value would be stored as
    # plaintext -- so the section is not offered for one.
    defp targetable?(%{type: "secret"}), do: false
    defp targetable?(_entry), do: true

    defp targeting_section(assigns) do
      ~H"""
      <section class="pf-targets">
        <h4 class="pf-targets-title">Targeting rules</h4>
        <p class="pf-targets-hint">
          Checked in order; the first match wins and overrides the value above.
        </p>

        <p :if={@targets == []} class="pf-targets-empty">No rules — every caller gets the value above.</p>

        <ol :if={@targets != []} class="pf-targets-list">
          <li :for={target <- @targets} class="pf-target">
            <span class="pf-target-rule">
              <span :for={{condition, index} <- Enum.with_index(target.conditions)} class="pf-target-cond">
                <span :if={index > 0} class="pf-target-and">and</span>
                <code>{condition.attribute}</code>
                <span class="pf-target-op">{operator_label(condition.operator)}</span>
                <code>{Enum.join(condition.values, ", ")}</code>
              </span>
              <span class="pf-target-arrow">&rarr;</span>
              <code class="pf-target-value">{target.value}</code>
            </span>
            <button
              type="button"
              class="pf-target-delete"
              phx-click="pf-delete-target"
              phx-value-target-id={target.id}
              aria-label={"Delete rule for #{@entry.key}"}
            >
              Delete
            </button>
          </li>
        </ol>

        <form
          id={"pf-target-form-#{@entry.key}"}
          class="pf-target-add"
          phx-submit="pf-add-target"
          phx-value-key={@entry.key}
        >
          <input
            type="text"
            name="target[attribute]"
            placeholder="attribute (e.g. company_id)"
            class="pf-input pf-target-input"
            aria-label="Attribute"
          />
          <select name="target[operator]" class="pf-select pf-target-op-select" aria-label="Operator">
            <option :for={operator <- PhoenixFlags.Target.operators()} value={operator}>
              {operator_label(to_string(operator))}
            </option>
          </select>
          <input
            type="text"
            name="target[values]"
            placeholder="values, comma separated"
            class="pf-input pf-target-input"
            aria-label="Values"
          />
          <.target_value_input entry={@entry} variants={@variants} select_options={@select_options} />
          <button type="submit" class="pf-btn">Add rule</button>
        </form>

        <p :if={@target_error} class="pf-field-error">{@target_error}</p>
      </section>
      """
    end

    # The forced value is constrained the same way the flag's own value is, so a
    # boolean offers true/false and a variant offers its declared arms.
    defp target_value_input(%{entry: %{type: "boolean"}} = assigns) do
      ~H"""
      <select name="target[value]" class="pf-select pf-target-input" aria-label="Forced value">
        <option value="true">true</option>
        <option value="false">false</option>
      </select>
      """
    end

    defp target_value_input(%{entry: %{type: "variant"}} = assigns) do
      ~H"""
      <select name="target[value]" class="pf-select pf-target-input" aria-label="Forced variant">
        <option :for={{label, value, _weight} <- @variants} value={value}>{label}</option>
      </select>
      """
    end

    defp target_value_input(%{entry: %{type: "select"}} = assigns) do
      ~H"""
      <select name="target[value]" class="pf-select pf-target-input" aria-label="Forced value">
        <option :for={{label, value} <- @select_options} value={value}>{label}</option>
      </select>
      """
    end

    defp target_value_input(assigns) do
      ~H"""
      <input
        type="text"
        name="target[value]"
        placeholder="forced value"
        class="pf-input pf-target-input"
        aria-label="Forced value"
      />
      """
    end

    defp operator_label("in"), do: "is one of"
    defp operator_label("not_in"), do: "is not one of"
    defp operator_label("eq"), do: "equals"
    defp operator_label("starts_with"), do: "starts with"
    defp operator_label(other), do: other

    defp modal_body_id(key), do: "pf-modal-body-#{key}"

    defp entry_info(assigns) do
      ~H"""
      <div class="pf-row-info">
        <p class="pf-row-label">{@entry.label}</p>
        <p :if={@entry.description} class="pf-row-desc">{@entry.description}</p>
      </div>
      """
    end

    defp config_input(%{entry: %{type: "secret"}} = assigns) do
      ~H"""
      <div>
        <input
          type="password"
          name="entry[value]"
          value=""
          autocomplete="new-password"
          placeholder="Enter new value (leave blank to clear)"
          class={input_class(@form, "pf-input")}
        />
        <.field_errors errors={@form[:value].errors} />
      </div>
      """
    end

    defp config_input(%{entry: %{type: "variant"}} = assigns) do
      assigns = assign(assigns, :weights, weight_map(assigns.entry, assigns.form))

      ~H"""
      <%!-- One grid rather than a flex row per variant: with separate rows the
            columns only line up when the labels happen to be the same width,
            and a longer label squeezed its input narrower. --%>
      <div class="pf-variant-edit">
        <%= for {label, name, _declared} <- @variants do %>
          <label for={"pf-w-#{@entry.key}-#{name}"} class="pf-variant-name">{label}</label>
          <input
            type="number"
            id={"pf-w-#{@entry.key}-#{name}"}
            name={"entry[variants][#{name}]"}
            value={Map.get(@weights, name, 0)}
            min="0"
            max="100"
            step="1"
            class={input_class(@form, "pf-input pf-variant-input")}
          />
          <span class="pf-variant-pct">%</span>
        <% end %>
        <p class={["pf-variant-total", if(weight_sum(@weights) == 100, do: "pf-variant-total-ok", else: "pf-variant-total-bad")]}>
          Total {weight_sum(@weights)}% {if weight_sum(@weights) == 100, do: "✓", else: "— must be 100"}
        </p>
        <.field_errors errors={@form[:value].errors} />
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

    defp variant_bars(assigns) do
      assigns = assign(assigns, :weights, weight_map(assigns.entry, nil))

      ~H"""
      <span class="pf-variant-summary">
        <span :for={{label, name, _declared} <- @variants} class="pf-variant-bar-row">
          <span class="pf-variant-bar-label">{label}</span>
          <span class="pf-variant-bar">
            <span class="pf-variant-bar-fill" style={"width: #{Map.get(@weights, name, 0)}%"}></span>
          </span>
          <span class="pf-variant-bar-pct">{Map.get(@weights, name, 0)}%</span>
        </span>
      </span>
      """
    end

    # Reads the split the operator is currently looking at: the form's value while
    # editing (which may be mid-edit and invalid), else the stored value. Uses the
    # lenient parser for exactly that reason.
    defp weight_map(entry, form) do
      value =
        case form && form[:value].value do
          value when is_binary(value) -> value
          _ -> entry.value || ""
        end

      case PhoenixFlags.Variant.parse_weights(value) do
        {:ok, weights} -> Map.new(weights)
        {:error, _message} -> %{}
      end
    end

    defp weight_sum(weights),
      do: Enum.reduce(weights, 0, fn {_name, weight}, sum -> sum + weight end)

    defp display_value(%{type: "select", value: value}, options) do
      Enum.find_value(options, value, fn {label, val} -> if val == value, do: label end)
    end

    defp display_value(%{type: "percentage", value: value}, _options), do: "#{value}%"
    defp display_value(%{value: value}, _options), do: value
  end
end
