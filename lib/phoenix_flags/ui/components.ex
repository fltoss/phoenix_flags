if Code.ensure_loaded?(Phoenix.Component) do
  defmodule PhoenixFlags.UI.Components do
    @moduledoc false
    use Phoenix.Component

    alias Phoenix.LiveView.JS

    @doc """
    A DOM id for `key`. A key is any non-empty string, and one with a dot,
    colon or space is not a usable id or selector -- `#pf-form-billing.enabled`
    selects a class. Keys that are already safe keep their readable id.
    """
    def dom_id(prefix, key) do
      if key =~ ~r/\A[A-Za-z0-9_-]+\z/,
        do: "#{prefix}-#{key}",
        else: "#{prefix}-x#{Base.encode16(key, case: :lower)}"
    end

    attr(:entry, :map, required: true)
    attr(:select_options, :list, default: [])
    attr(:variants, :list, default: [])
    attr(:declared, :boolean, default: true)

    @doc "One flag's row: what it is, its value, and the control that changes it."
    def config_row(assigns) do
      assigns = assign(assigns, :label_id, dom_id("pf-label", assigns.entry.key))

      ~H"""
      <div class="pf-row" id={dom_id("pf-row", @entry.key)}>
        <.entry_info entry={@entry} declared={@declared} label_id={@label_id} />
        <div class="pf-row-actions">
          <%= if @entry.type == "boolean" do %>
            <.toggle entry={@entry} label_id={@label_id} />
          <% else %>
            <.row_value entry={@entry} select_options={@select_options} variants={@variants} />
            <button
              type="button"
              phx-click={JS.push_focus() |> JS.push("pf-edit", value: %{key: @entry.key})}
              phx-value-key={@entry.key}
              class="pf-row-edit-btn"
              aria-describedby={@label_id}
            >
              Edit
            </button>
          <% end %>
        </div>
      </div>
      """
    end

    defp toggle(assigns) do
      ~H"""
      <button
        type="button"
        phx-click="pf-toggle"
        phx-value-key={@entry.key}
        class="pf-toggle"
        role="switch"
        aria-checked={to_string(@entry.value == "true")}
        aria-labelledby={@label_id}
      >
        <span class="pf-toggle-knob"></span>
      </button>
      <span class={[
        "pf-toggle-label",
        if(@entry.value == "true", do: "pf-toggle-label-on", else: "pf-toggle-label-off")
      ]}>
        {if @entry.value == "true", do: "Enabled", else: "Disabled"}
      </span>
      """
    end

    defp row_value(%{entry: %{type: "secret"}} = assigns) do
      ~H"""
      <span class="pf-row-value">{if @entry.value in [nil, ""], do: "Not set", else: "Set"}</span>
      """
    end

    defp row_value(%{entry: %{type: "variant"}} = assigns) do
      ~H"""
      <.variant_bars entry={@entry} variants={@variants} />
      """
    end

    defp row_value(assigns) do
      ~H"""
      <span class="pf-row-value">{display_value(@entry, @select_options)}</span>
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
    edited, rather than inline in the row. Focus stays inside it while open and
    returns to the Edit button that opened it, however it closes.
    """
    def edit_modal(assigns) do
      assigns =
        assigns
        |> assign(:title_id, dom_id("pf-modal-title", assigns.entry.key))
        |> assign(:body_id, dom_id("pf-modal-body", assigns.entry.key))
        |> assign(:form_id, dom_id("pf-form", assigns.entry.key))

      ~H"""
      <div
        class="pf-modal-overlay"
        id="pf-modal"
        phx-window-keydown="pf-cancel"
        phx-key="Escape"
        phx-remove={JS.pop_focus()}
      >
        <div class="pf-modal-backdrop" phx-click="pf-cancel"></div>

        <.focus_wrap
          id="pf-modal-dialog"
          class="pf-modal"
          role="dialog"
          aria-modal="true"
          aria-labelledby={@title_id}
          phx-mounted={JS.focus_first(to: "##{@body_id}")}
        >
          <div class="pf-modal-header">
            <h3 class="pf-modal-title" id={@title_id}>{@entry.label}</h3>
            <button type="button" class="pf-modal-close" phx-click="pf-cancel" aria-label="Close">
              &times;
            </button>
          </div>

          <div class="pf-modal-body" id={@body_id}>
            <p :if={@entry.description} class="pf-modal-desc">{@entry.description}</p>

            <%!-- Two sibling forms: HTML forbids nesting, and the targeting
                  section needs its own submit. --%>
            <form
              id={@form_id}
              phx-submit="pf-save"
              phx-change={if @entry.type == "variant", do: "pf-validate"}
              phx-value-key={@entry.key}
            >
              <.config_input
                entry={@entry}
                form={@form}
                select_options={@select_options}
                variants={@variants}
                label_id={@title_id}
              />
            </form>

            <.targeting_section
              :if={@entry.type != "secret"}
              entry={@entry}
              targets={@targets}
              target_error={@target_error}
              variants={@variants}
              select_options={@select_options}
            />
          </div>

          <%!-- The footer sits outside both forms so it stays at the bottom of
                the dialog; `form=` ties Save to the value form wherever it is. --%>
          <div class="pf-modal-footer">
            <button
              :if={@entry.type == "secret" and @entry.value not in [nil, ""]}
              type="button"
              phx-click="pf-clear-secret"
              phx-value-key={@entry.key}
              class="pf-btn pf-btn-danger"
            >
              Clear
            </button>
            <button type="button" phx-click="pf-cancel" class="pf-btn">Cancel</button>
            <button type="submit" form={@form_id} class="pf-btn pf-btn-primary">Save</button>
          </div>
        </.focus_wrap>
      </div>
      """
    end

    attr(:notice, :any, required: true)

    @doc "A dismissable line saying what went wrong, or what happened instead."
    def notice(assigns) do
      ~H"""
      <div
        :if={@notice}
        id="pf-notice"
        class={["pf-flash", "pf-flash-#{elem(@notice, 0)}"]}
        role={if elem(@notice, 0) == :error, do: "alert", else: "status"}
      >
        <span>{elem(@notice, 1)}</span>
        <button type="button" class="pf-flash-dismiss" phx-click="pf-dismiss-notice" aria-label="Dismiss">
          &times;
        </button>
      </div>
      """
    end

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
          id={dom_id("pf-target-form", @entry.key)}
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

        <p :if={@target_error} class="pf-field-error" role="alert">{@target_error}</p>
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

    defp entry_info(assigns) do
      ~H"""
      <div class="pf-row-info">
        <p class="pf-row-label" id={@label_id}>{@entry.label}</p>
        <p :if={@entry.description} class="pf-row-desc">{@entry.description}</p>
        <p :if={!@declared} class="pf-row-undeclared">
          No longer declared in code. Kept so a rolling deploy cannot lose it;
          <code>prune_undeclared/0</code> deletes it.
        </p>
      </div>
      """
    end

    # A blank save keeps the stored secret: the field starts empty, so Enter in
    # it used to erase a production key. Clearing is the Clear button.
    defp config_input(%{entry: %{type: "secret"}} = assigns) do
      ~H"""
      <div>
        <input
          type="password"
          name="entry[value]"
          value=""
          autocomplete="new-password"
          placeholder="Enter a new value (blank keeps the stored one)"
          aria-labelledby={@label_id}
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
            columns only line up when the labels happen to be the same width. --%>
      <div class="pf-variant-edit">
        <%= for {label, name, _declared} <- @variants do %>
          <label for={dom_id("pf-w", "#{@entry.key}-#{name}")} class="pf-variant-name">{label}</label>
          <input
            type="number"
            id={dom_id("pf-w", "#{@entry.key}-#{name}")}
            name={"entry[variants][#{name}]"}
            value={Map.get(@weights, name, 0)}
            min="0"
            max="100"
            step="1"
            class={input_class(@form, "pf-input pf-variant-input")}
          />
          <span class="pf-variant-pct">%</span>
        <% end %>
        <p
          class={["pf-variant-total", if(weight_sum(@weights) == 100, do: "pf-variant-total-ok", else: "pf-variant-total-bad")]}
          aria-live="polite"
        >
          Total {weight_sum(@weights)}% {if weight_sum(@weights) == 100, do: "✓", else: "— must be 100"}
        </p>
        <.field_errors errors={@form[:value].errors} />
      </div>
      """
    end

    defp config_input(%{entry: %{type: "select"}} = assigns) do
      ~H"""
      <div>
        <select name="entry[value]" aria-labelledby={@label_id} class={input_class(@form, "pf-select")}>
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
      assigns = assign(assigns, :step, if(type == "integer", do: "1", else: "any"))

      ~H"""
      <div>
        <input
          type="number"
          name="entry[value]"
          value={@form[:value].value}
          step={@step}
          aria-labelledby={@label_id}
          class={input_class(@form, "pf-input")}
        />
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
          aria-labelledby={@label_id}
          class={input_class(@form, "pf-input")}
        />
        <.field_errors errors={@form[:value].errors} />
      </div>
      """
    end

    defp field_errors(assigns) do
      ~H"""
      <p :for={{message, _opts} <- @errors} class="pf-field-error" role="alert">{message}</p>
      """
    end

    defp input_class(form, base) do
      if form[:value].errors != [], do: "#{base} pf-input-error", else: base
    end

    # Drawn as SVG so the width is an attribute: an inline style= needs
    # 'unsafe-inline' in a host's style-src.
    defp variant_bars(assigns) do
      assigns = assign(assigns, :weights, weight_map(assigns.entry, nil))

      ~H"""
      <span class="pf-variant-summary">
        <span :for={{label, name, _declared} <- @variants} class="pf-variant-bar-row">
          <span class="pf-variant-bar-label">{label}</span>
          <svg class="pf-variant-bar" viewBox="0 0 100 8" preserveAspectRatio="none" aria-hidden="true">
            <rect class="pf-variant-bar-fill" width={Map.get(@weights, name, 0)} height="8" />
          </svg>
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
