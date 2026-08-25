defmodule PhoenixFlags.UI.DashboardLiveTest do
  use PhoenixFlags.ConnCase

  alias PhoenixFlags.Entry

  setup do
    config = %PhoenixFlags.Config{
      otp_app: :phoenix_flags,
      repo: TestRepo,
      name: TestConfig,
      cache_enabled: false
    }

    :persistent_term.put({PhoenixFlags, TestConfig, :config}, config)

    :ok
  end

  describe "renders" do
    test "shows the dashboard heading", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/flags")

      assert html =~ "System Flags"
      assert html =~ "Changes take effect immediately"
    end

    test "shows empty state when no flags in DB", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/flags")

      assert html =~ "No flags configured"
    end

    test "shows boolean flag with toggle", %{conn: conn} do
      TestRepo.insert!(%Entry{
        key: "my_bool",
        value: "true",
        type: "boolean",
        category: "test",
        label: "My Boolean"
      })

      {:ok, _view, html} = live(conn, "/flags")

      assert html =~ "My Boolean"
      assert html =~ "Enabled"
      assert html =~ ~s(role="switch")
    end

    test "shows non-boolean flag with value", %{conn: conn} do
      TestRepo.insert!(%Entry{
        key: "max_retries",
        value: "5",
        type: "integer",
        category: "system",
        label: "Max Retries"
      })

      {:ok, _view, html} = live(conn, "/flags")

      assert html =~ "Max Retries"
      assert html =~ "5"
    end

    test "shows percentage with % suffix", %{conn: conn} do
      TestRepo.insert!(%Entry{
        key: "fee_rate",
        value: "12.5",
        type: "percentage",
        category: "fees",
        label: "Fee Rate"
      })

      {:ok, _view, html} = live(conn, "/flags")

      assert html =~ "12.5%"
    end

    test "groups entries by category", %{conn: conn} do
      TestRepo.insert!(%Entry{
        key: "flag_a",
        value: "true",
        type: "boolean",
        category: "alpha",
        label: "Flag A"
      })

      TestRepo.insert!(%Entry{
        key: "flag_b",
        value: "42",
        type: "integer",
        category: "beta",
        label: "Flag B"
      })

      {:ok, _view, html} = live(conn, "/flags")

      assert html =~ "Alpha"
      assert html =~ "Beta"
      assert html =~ "Flag A"
      assert html =~ "Flag B"
    end
  end

  describe "toggle" do
    test "toggles a boolean flag from true to false", %{conn: conn} do
      TestRepo.insert!(%Entry{
        key: "toggle_me",
        value: "true",
        type: "boolean",
        category: "test",
        label: "Toggle Me"
      })

      {:ok, view, _html} = live(conn, "/flags")

      html =
        view
        |> element(~s(button[phx-value-key="toggle_me"]))
        |> render_click()

      assert html =~ "Disabled"

      entry = TestRepo.get_by(Entry, key: "toggle_me")
      assert entry.value == "false"
    end

    test "toggles a boolean flag from false to true", %{conn: conn} do
      TestRepo.insert!(%Entry{
        key: "toggle_me",
        value: "false",
        type: "boolean",
        category: "test",
        label: "Toggle Me"
      })

      {:ok, view, _html} = live(conn, "/flags")

      html =
        view
        |> element(~s(button[phx-value-key="toggle_me"]))
        |> render_click()

      assert html =~ "Enabled"

      entry = TestRepo.get_by(Entry, key: "toggle_me")
      assert entry.value == "true"
    end

    test "ignores a forged toggle event targeting a non-boolean flag", %{conn: conn} do
      TestRepo.insert!(%Entry{
        key: "smtp_host",
        value: "smtp.example.com",
        type: "string",
        category: "system",
        label: "SMTP Host"
      })

      {:ok, view, _html} = live(conn, "/flags")

      # No toggle is rendered for a string flag — send the event directly,
      # as a tampered client could.
      render_click(view, "pf-toggle", %{"key" => "smtp_host"})

      entry = TestRepo.get_by(Entry, key: "smtp_host")
      assert entry.value == "smtp.example.com"
    end

    test "ignores a forged toggle event for an unknown key", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/flags")

      render_click(view, "pf-toggle", %{"key" => "does_not_exist"})
    end
  end

  describe "edit" do
    test "shows edit form when clicking Edit", %{conn: conn} do
      TestRepo.insert!(%Entry{
        key: "editable",
        value: "5",
        type: "integer",
        category: "test",
        label: "Editable"
      })

      {:ok, view, _html} = live(conn, "/flags")

      html =
        view
        |> element(~s(button[phx-value-key="editable"]))
        |> render_click()

      assert html =~ "Save"
      assert html =~ "Cancel"
    end

    test "saves an updated value", %{conn: conn} do
      TestRepo.insert!(%Entry{
        key: "updatable",
        value: "5",
        type: "integer",
        category: "test",
        label: "Updatable"
      })

      {:ok, view, _html} = live(conn, "/flags")

      # Enter edit mode
      view
      |> element(~s(button[phx-value-key="updatable"]))
      |> render_click()

      # Submit new value
      html =
        view
        |> form("#pf-form-updatable", entry: %{value: "10"})
        |> render_submit()

      assert html =~ "10"
      refute html =~ "Save"

      entry = TestRepo.get_by(Entry, key: "updatable")
      assert entry.value == "10"
    end

    test "shows validation error for invalid value", %{conn: conn} do
      TestRepo.insert!(%Entry{
        key: "validated",
        value: "50",
        type: "percentage",
        category: "test",
        label: "Validated"
      })

      {:ok, view, _html} = live(conn, "/flags")

      view
      |> element(~s(button[phx-value-key="validated"]))
      |> render_click()

      html =
        view
        |> form("#pf-form-validated", entry: %{value: "150"})
        |> render_submit()

      assert html =~ "must be between 0 and 100"
    end

    test "cancels editing", %{conn: conn} do
      TestRepo.insert!(%Entry{
        key: "cancelable",
        value: "3",
        type: "integer",
        category: "test",
        label: "Cancelable"
      })

      {:ok, view, _html} = live(conn, "/flags")

      view
      |> element(~s(button[phx-value-key="cancelable"]))
      |> render_click()

      html =
        view
        |> element("button", "Cancel")
        |> render_click()

      refute html =~ "Save"
    end
  end

  describe "select" do
    test "shows select options for select type", %{conn: conn} do
      TestRepo.insert!(%Entry{
        key: "email_provider",
        value: "mailjet",
        type: "select",
        category: "email",
        label: "Email Provider"
      })

      {:ok, view, _html} = live(conn, "/flags")

      # Enter edit mode
      html =
        view
        |> element(~s(button[phx-value-key="email_provider"]))
        |> render_click()

      assert html =~ "<select"
    end

    test "displays select label instead of raw value", %{conn: conn} do
      TestRepo.insert!(%Entry{
        key: "email_provider",
        value: "mailjet",
        type: "select",
        category: "email",
        label: "Email Provider"
      })

      {:ok, _view, html} = live(conn, "/flags")

      # Should show the label, not the raw value
      assert html =~ "Email Provider"
    end
  end

  describe "select validation (mounted with a config that declares options)" do
    setup do
      config = %PhoenixFlags.Config{
        otp_app: :phoenix_flags,
        repo: TestRepo,
        name: PhoenixFlags.TestSelectConfig,
        cache_enabled: false
      }

      :persistent_term.put({PhoenixFlags, PhoenixFlags.TestSelectConfig, :config}, config)

      TestRepo.insert!(%Entry{
        key: "email_provider",
        value: "mailjet",
        type: "select",
        category: "email",
        label: "Email Provider"
      })

      :ok
    end

    test "renders the declared options", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/select-flags")

      html =
        view
        |> element(~s(button[phx-value-key="email_provider"]))
        |> render_click()

      assert html =~ ~s(value="mailjet")
      assert html =~ ~s(value="ses")
    end

    test "saving a declared option succeeds", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/select-flags")

      view
      |> element(~s(button[phx-value-key="email_provider"]))
      |> render_click()

      view
      |> element("#pf-form-email_provider")
      |> render_submit(%{"entry" => %{"value" => "ses"}})

      assert TestRepo.get_by!(Entry, key: "email_provider").value == "ses"
    end

    test "a forged submit with an undeclared value is rejected and shown as an error",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/select-flags")

      view
      |> element(~s(button[phx-value-key="email_provider"]))
      |> render_click()

      # The rendered <select> constrains a real browser, but event params are
      # client-controlled — this is what a forged phx-submit looks like.
      html =
        view
        |> element("#pf-form-email_provider")
        |> render_submit(%{"entry" => %{"value" => "postmark"}})

      assert html =~ "must be one of: mailjet, ses"
      assert TestRepo.get_by!(Entry, key: "email_provider").value == "mailjet"
    end
  end

  describe "edit modal" do
    setup do
      TestRepo.insert!(%Entry{
        key: "max_retries",
        value: "5",
        type: "integer",
        category: "system",
        label: "Max Retries",
        description: "How many times to retry."
      })

      :ok
    end

    test "no dialog is rendered until Edit is clicked", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/flags")

      refute html =~ "pf-modal"
      refute html =~ ~s(role="dialog")
    end

    test "Edit opens a labelled dialog and leaves the row in place", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/flags")

      html = view |> element(~s(button[phx-value-key="max_retries"])) |> render_click()

      assert html =~ ~s(role="dialog")
      assert html =~ ~s(aria-modal="true")
      assert html =~ ~s(aria-labelledby="pf-modal-title-max_retries")
      assert html =~ ~s(id="pf-modal-title-max_retries")
      assert html =~ "How many times to retry."
      assert html =~ ~s(name="entry[value]")

      # The row itself is no longer replaced by the editor.
      assert html =~ "pf-row"
    end

    test "focus is directed into the body, not the close button", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/flags")

      html = view |> element(~s(button[phx-value-key="max_retries"])) |> render_click()

      # JS.focus_first/0 walks DOM order and would land on the header's close
      # button, which is both wrong for keyboard users and why the x rendered
      # with a focus ring on open. It must be scoped to the body instead.
      assert html =~ ~s(id="pf-modal-body-max_retries")

      assert html =~
               ~s(phx-mounted="[[&quot;focus_first&quot;,{&quot;to&quot;:&quot;#pf-modal-body-max_retries&quot;}]]")
    end

    test "the footer is the last thing in the dialog, below the targeting section",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/flags")

      html = view |> element(~s(button[phx-value-key="max_retries"])) |> render_click()

      body_at = :binary.match(html, "pf-modal-body") |> elem(0)
      targets_at = :binary.match(html, "pf-targets") |> elem(0)
      footer_at = :binary.match(html, "pf-modal-footer") |> elem(0)

      # The footer used to sit inside the value form, which put Save and Cancel
      # in the middle of the dialog once the targeting section appeared below.
      assert body_at < targets_at
      assert targets_at < footer_at
    end

    test "Save submits the value form from outside it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/flags")

      html = view |> element(~s(button[phx-value-key="max_retries"])) |> render_click()

      # HTML forbids nesting the value form and the targeting form, so the
      # shared footer lives outside both and the submit button is associated by
      # `form=`. Without that attribute the button would submit nothing.
      assert html =~ ~s(<button type="submit" form="pf-form-max_retries")
    end

    test "Cancel closes the dialog", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/flags")

      view |> element(~s(button[phx-value-key="max_retries"])) |> render_click()
      html = view |> element(~s(.pf-modal-footer button), "Cancel") |> render_click()

      refute html =~ ~s(role="dialog")
    end

    test "the close control closes the dialog", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/flags")

      view |> element(~s(button[phx-value-key="max_retries"])) |> render_click()
      html = view |> element(".pf-modal-close") |> render_click()

      refute html =~ ~s(role="dialog")
    end

    test "clicking the backdrop closes the dialog", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/flags")

      view |> element(~s(button[phx-value-key="max_retries"])) |> render_click()
      html = view |> element(".pf-modal-backdrop") |> render_click()

      refute html =~ ~s(role="dialog")
    end

    test "Escape closes the dialog", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/flags")

      view |> element(~s(button[phx-value-key="max_retries"])) |> render_click()
      html = element(view, ".pf-modal-overlay") |> render_keydown(%{"key" => "Escape"})

      refute html =~ ~s(role="dialog")
    end

    test "saving from the dialog persists and closes it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/flags")

      view |> element(~s(button[phx-value-key="max_retries"])) |> render_click()

      html =
        view
        |> element("#pf-form-max_retries")
        |> render_submit(%{"entry" => %{"value" => "9"}})

      refute html =~ ~s(role="dialog")
      assert TestRepo.get_by!(Entry, key: "max_retries").value == "9"
    end

    test "a validation error keeps the dialog open and shows the message", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/flags")

      view |> element(~s(button[phx-value-key="max_retries"])) |> render_click()

      html =
        view
        |> element("#pf-form-max_retries")
        |> render_submit(%{"entry" => %{"value" => "not-a-number"}})

      assert html =~ ~s(role="dialog")
      assert html =~ "must be a whole number"
      assert TestRepo.get_by!(Entry, key: "max_retries").value == "5"
    end

    test "a secret is edited through the dialog too", %{conn: conn} do
      TestRepo.insert!(%Entry{
        key: "api_key",
        value: "",
        type: "secret",
        category: "system",
        label: "API Key"
      })

      {:ok, view, _html} = live(conn, "/flags")

      html = view |> element(~s(button[phx-value-key="api_key"])) |> render_click()

      assert html =~ ~s(role="dialog")
      assert html =~ ~s(type="password")
      assert html =~ ~s(autocomplete="new-password")
    end

    test "only one dialog exists at a time", %{conn: conn} do
      TestRepo.insert!(%Entry{
        key: "other",
        value: "x",
        type: "string",
        category: "system",
        label: "Other"
      })

      {:ok, view, _html} = live(conn, "/flags")

      view |> element(~s(button[phx-value-key="max_retries"])) |> render_click()
      html = view |> element(~s(button[phx-value-key="other"])) |> render_click()

      assert html |> String.split(~s(role="dialog")) |> length() == 2
      assert html =~ ~s(aria-labelledby="pf-modal-title-other")
      refute html =~ ~s(aria-labelledby="pf-modal-title-max_retries")
    end
  end

  describe "targeting rules in the dialog" do
    setup do
      TestRepo.insert!(%Entry{
        key: "max_retries",
        value: "5",
        type: "integer",
        category: "system",
        label: "Max Retries"
      })

      TestRepo.insert!(%Entry{
        key: "api_key",
        value: "",
        type: "secret",
        category: "system",
        label: "API Key"
      })

      :ok
    end

    defp open_editor(view, key) do
      view |> element(~s(button[phx-value-key="#{key}"])) |> render_click()
    end

    defp add_rule(view, key, params) do
      view |> element("#pf-target-form-#{key}") |> render_submit(%{"target" => params})
    end

    test "the section explains itself and starts empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/flags")

      html = open_editor(view, "max_retries")

      assert html =~ "Targeting rules"
      assert html =~ "the first match wins"
      assert html =~ "No rules"
    end

    test "adding a rule lists it and applies it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/flags")
      open_editor(view, "max_retries")

      html =
        add_rule(view, "max_retries", %{
          "attribute" => "company_id",
          "operator" => "in",
          "values" => "123, 456",
          "value" => "9000"
        })

      assert html =~ "company_id"
      assert html =~ "is one of"
      assert html =~ "123, 456"
      assert html =~ "9000"
      refute html =~ "No rules"

      assert [target] = TestConfig.targets("max_retries")
      assert target.value == "9000"

      assert [%{attribute: "company_id", operator: "in", values: ["123", "456"]}] =
               target.conditions
    end

    test "deleting a rule removes it", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/flags")
      open_editor(view, "max_retries")

      add_rule(view, "max_retries", %{
        "attribute" => "company_id",
        "operator" => "in",
        "values" => "123",
        "value" => "9000"
      })

      assert [_] = TestConfig.targets("max_retries")

      html = view |> element(".pf-target-delete") |> render_click()

      assert html =~ "No rules"
      assert TestConfig.targets("max_retries") == []
    end

    test "a rule value that is wrong for the type is reported, not saved", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/flags")
      open_editor(view, "max_retries")

      html =
        add_rule(view, "max_retries", %{
          "attribute" => "company_id",
          "operator" => "in",
          "values" => "123",
          "value" => "not-a-number"
        })

      assert html =~ "must be a whole number"
      assert TestConfig.targets("max_retries") == []
    end

    test "a blank attribute is reported", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/flags")
      open_editor(view, "max_retries")

      html =
        add_rule(view, "max_retries", %{
          "attribute" => "  ",
          "operator" => "in",
          "values" => "123",
          "value" => "9"
        })

      assert html =~ "blank" or html =~ "must not be"
      assert TestConfig.targets("max_retries") == []
    end

    test "no values is reported rather than creating a rule that matches everyone",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/flags")
      open_editor(view, "max_retries")

      html =
        add_rule(view, "max_retries", %{
          "attribute" => "company_id",
          "operator" => "not_in",
          "values" => "  ,  ",
          "value" => "9"
        })

      assert html =~ "at least one value"
      assert TestConfig.targets("max_retries") == []
    end

    test "a :secret flag is not offered a targeting section", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/flags")

      html = open_editor(view, "api_key")

      assert html =~ ~s(role="dialog")
      refute html =~ "Targeting rules"
    end

    test "rules do not leak between dialogs", %{conn: conn} do
      TestRepo.insert!(%Entry{
        key: "other",
        value: "x",
        type: "string",
        category: "system",
        label: "Other"
      })

      {:ok, view, _html} = live(conn, "/flags")
      open_editor(view, "max_retries")

      add_rule(view, "max_retries", %{
        "attribute" => "company_id",
        "operator" => "in",
        "values" => "123",
        "value" => "9000"
      })

      view |> element(".pf-modal-close") |> render_click()
      html = open_editor(view, "other")

      assert html =~ "No rules"
      refute html =~ "9000"
    end

    test "a forged delete for an unknown rule does not crash the view", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/flags")
      open_editor(view, "max_retries")

      assert render_hook_safe(view, "pf-delete-target", %{"target-id" => Ecto.UUID.generate()})
      assert render_hook_safe(view, "pf-delete-target", %{"target-id" => "nonsense"})
      assert render(view) =~ "System Flags"
    end

    test "a forged add with a malformed payload does not crash the view", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/flags")
      open_editor(view, "max_retries")

      for params <- [%{}, %{"attribute" => %{"a" => "b"}}, %{"values" => ["a"]}] do
        assert render_hook_safe(view, "pf-add-target", %{
                 "key" => "max_retries",
                 "target" => params
               })
      end

      assert render(view) =~ "System Flags"
      assert TestConfig.targets("max_retries") == []
    end
  end

  describe "forged events cannot crash the dashboard" do
    setup do
      TestRepo.insert!(%Entry{
        key: "my_bool",
        value: "true",
        type: "boolean",
        category: "test",
        label: "My Boolean"
      })

      :ok
    end

    test "pf-save naming a key that does not exist", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/flags")

      # update_entry/4 returns {:error, :not_found} for an unknown key, which is
      # not a changeset — to_form/2 used to raise on it and take the view down.
      assert render_hook_safe(view, "pf-save", %{
               "key" => "no-such-flag",
               "entry" => %{"value" => "x"}
             })

      assert render(view) =~ "System Flags"
    end

    test "an unknown event name", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/flags")

      assert render_hook_safe(view, "pf-nonsense", %{"anything" => "goes"})
      assert render(view) =~ "System Flags"
    end

    test "a known event with a missing field", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/flags")

      for {event, params} <- [
            {"pf-save", %{"key" => "my_bool"}},
            {"pf-save", %{}},
            {"pf-validate", %{"key" => "my_bool"}},
            {"pf-toggle", %{}},
            {"pf-edit", %{}}
          ] do
        assert render_hook_safe(view, event, params),
               "#{event} #{inspect(params)} killed the view"
      end

      assert render(view) =~ "System Flags"
    end

    test "pf-toggle on a non-boolean flag is ignored", %{conn: conn} do
      TestRepo.insert!(%Entry{
        key: "a_string",
        value: "hello",
        type: "string",
        category: "test",
        label: "A String"
      })

      {:ok, view, _html} = live(conn, "/flags")

      assert render_hook_safe(view, "pf-toggle", %{"key" => "a_string"})
      assert TestRepo.get_by!(Entry, key: "a_string").value == "hello"
    end

    # Pushes an event straight at the LiveView, bypassing form/element helpers so
    # the payload shape is entirely ours. Returns true if the view survived.
    defp render_hook_safe(view, event, params) do
      Phoenix.LiveViewTest.render_click(view, event, params)
      true
    catch
      :exit, reason -> flunk("view exited on #{event}: #{inspect(reason)}")
    end
  end

  describe "variant" do
    setup do
      config = %PhoenixFlags.Config{
        otp_app: :phoenix_flags,
        repo: TestRepo,
        name: PhoenixFlags.TestVariantConfig,
        cache_enabled: false
      }

      :persistent_term.put({PhoenixFlags, PhoenixFlags.TestVariantConfig, :config}, config)

      TestRepo.insert!(%Entry{
        key: "checkout_flow",
        value: "control=90,new_flow=10",
        type: "variant",
        category: "experiments",
        label: "Checkout flow"
      })

      :ok
    end

    test "shows the split as labelled bars rather than a raw value", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/variant-flags")

      assert html =~ "Checkout flow"
      assert html =~ "Control"
      assert html =~ "New flow"
      assert html =~ "90%"
      assert html =~ "10%"
      # The stored string itself must not be what an operator reads.
      refute html =~ "control=90,new_flow=10"
    end

    test "the editor renders one input per declared variant, with a running total",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/variant-flags")

      html =
        view
        |> element(~s(button[phx-value-key="checkout_flow"]))
        |> render_click()

      assert html =~ ~s(name="entry[variants][control]")
      assert html =~ ~s(name="entry[variants][new_flow]")
      assert html =~ "Total 100%"
    end

    test "the weight inputs share one grid column so they align", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/variant-flags")

      html = view |> element(~s(button[phx-value-key="checkout_flow"])) |> render_click()

      # Each row used to be its own flex container, so the columns only lined up
      # when the labels happened to be the same width -- a longer label squeezed
      # its input narrower. The label/input/% cells must be direct children of a
      # single grid, with no per-row wrapper.
      refute html =~ "pf-variant-field"

      editor = html |> String.split(~s(<div class="pf-variant-edit">), parts: 2) |> List.last()
      label_at = :binary.match(editor, "pf-variant-name") |> elem(0)
      input_at = :binary.match(editor, "pf-variant-input") |> elem(0)

      assert label_at < input_at
      # Two variants, so two of each cell.
      assert editor |> String.split("pf-variant-input") |> length() == 3
      assert editor |> String.split("pf-variant-pct") |> length() == 3
    end

    test "saving a valid split writes it in declared order", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/variant-flags")

      view |> element(~s(button[phx-value-key="checkout_flow"])) |> render_click()

      view
      |> element("#pf-form-checkout_flow")
      |> render_submit(%{"entry" => %{"variants" => %{"new_flow" => "40", "control" => "60"}}})

      # Declared order, not the order the params happened to arrive in — bucket
      # order is what makes a rollout sticky.
      assert TestRepo.get_by!(Entry, key: "checkout_flow").value == "control=60,new_flow=40"
    end

    test "a split that does not total 100 is rejected and shown as an error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/variant-flags")

      view |> element(~s(button[phx-value-key="checkout_flow"])) |> render_click()

      html =
        view
        |> element("#pf-form-checkout_flow")
        |> render_submit(%{"entry" => %{"variants" => %{"control" => "60", "new_flow" => "10"}}})

      assert html =~ "weights must total 100, got 70"
      assert TestRepo.get_by!(Entry, key: "checkout_flow").value == "control=90,new_flow=10"
    end

    test "a forged submit naming an undeclared variant is rejected", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/variant-flags")

      view |> element(~s(button[phx-value-key="checkout_flow"])) |> render_click()

      # variant_attrs/3 rebuilds the value from the *declared* variants, so a
      # forged extra field cannot introduce a name; the missing declared one
      # defaults to 0 and the total then fails.
      html =
        view
        |> element("#pf-form-checkout_flow")
        |> render_submit(%{"entry" => %{"variants" => %{"control" => "50", "bogus" => "50"}}})

      assert html =~ "weights must total 100"
      assert TestRepo.get_by!(Entry, key: "checkout_flow").value == "control=90,new_flow=10"
    end

    test "a forged value field is discarded in favour of the declared rebuild",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/variant-flags")

      view |> element(~s(button[phx-value-key="checkout_flow"])) |> render_click()

      # The form posts its own entry[variants][...] fields, so variant_attrs/3
      # rebuilds `value` from the declared variants and drops anything the
      # client tried to set directly. The stored split is therefore unchanged.
      view
      |> element("#pf-form-checkout_flow")
      |> render_submit(%{"entry" => %{"value" => "control=50,bogus=50"}})

      assert TestRepo.get_by!(Entry, key: "checkout_flow").value == "control=90,new_flow=10"
    end

    test "a forged weight that is not a string cannot crash the LiveView", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/variant-flags")

      view |> element(~s(button[phx-value-key="checkout_flow"])) |> render_click()

      # Params are client-controlled: a nested map where a number belongs used to
      # reach string interpolation and raise Protocol.UndefinedError inside the
      # LiveView process. It must degrade to an ordinary validation error.
      for forged <- [%{"nested" => "map"}, ["a", "list"]] do
        html =
          view
          |> element("#pf-form-checkout_flow")
          |> render_submit(%{
            "entry" => %{"variants" => %{"control" => forged, "new_flow" => "10"}}
          })

        assert html =~ "weights must total 100"
        assert TestRepo.get_by!(Entry, key: "checkout_flow").value == "control=90,new_flow=10"
      end
    end

    test "a forged weight is also survivable on the change event", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/variant-flags")

      view |> element(~s(button[phx-value-key="checkout_flow"])) |> render_click()

      html =
        view
        |> element("#pf-form-checkout_flow")
        |> render_change(%{
          "entry" => %{"variants" => %{"control" => %{"a" => "b"}, "new_flow" => "10"}}
        })

      assert html =~ "Total 10%"
    end

    test "the running total updates live as weights change", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/variant-flags")

      view |> element(~s(button[phx-value-key="checkout_flow"])) |> render_click()

      html =
        view
        |> element("#pf-form-checkout_flow")
        |> render_change(%{"entry" => %{"variants" => %{"control" => "70", "new_flow" => "10"}}})

      assert html =~ "Total 80%"
      assert html =~ "must be 100"
      # A change event must not write.
      assert TestRepo.get_by!(Entry, key: "checkout_flow").value == "control=90,new_flow=10"
    end
  end

  describe "secret" do
    test "shows 'Not set' for an empty secret", %{conn: conn} do
      TestRepo.insert!(%Entry{
        key: "api_key",
        value: "",
        type: "secret",
        category: "ai",
        label: "API Key"
      })

      {:ok, _view, html} = live(conn, "/flags")

      assert html =~ "API Key"
      assert html =~ "Not set"
      refute html =~ "some-cipher"
    end

    test "shows 'Set' for a populated secret without leaking the ciphertext", %{conn: conn} do
      TestRepo.insert!(%Entry{
        key: "api_key",
        value: "some-cipher",
        type: "secret",
        category: "ai",
        label: "API Key"
      })

      {:ok, _view, html} = live(conn, "/flags")

      assert html =~ "Set"
      refute html =~ "some-cipher"
    end

    test "edit form renders a password input with no pre-filled value", %{conn: conn} do
      TestRepo.insert!(%Entry{
        key: "api_key",
        value: "some-cipher",
        type: "secret",
        category: "ai",
        label: "API Key"
      })

      {:ok, view, _html} = live(conn, "/flags")

      html =
        view
        |> element(~s(button[phx-value-key="api_key"]))
        |> render_click()

      assert html =~ ~s(type="password")
      assert html =~ ~s(autocomplete="new-password")
      refute html =~ ~s(value="some-cipher")
    end
  end
end
