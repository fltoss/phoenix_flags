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
        |> form(~s(form[phx-value-key="updatable"]), entry: %{value: "10"})
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
        |> form(~s(form[phx-value-key="validated"]), entry: %{value: "150"})
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
      |> element(~s(form[phx-value-key="email_provider"]))
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
        |> element(~s(form[phx-value-key="email_provider"]))
        |> render_submit(%{"entry" => %{"value" => "postmark"}})

      assert html =~ "must be one of: mailjet, ses"
      assert TestRepo.get_by!(Entry, key: "email_provider").value == "mailjet"
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

    test "saving a valid split writes it in declared order", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/variant-flags")

      view |> element(~s(button[phx-value-key="checkout_flow"])) |> render_click()

      view
      |> element(~s(form[phx-value-key="checkout_flow"]))
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
        |> element(~s(form[phx-value-key="checkout_flow"]))
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
        |> element(~s(form[phx-value-key="checkout_flow"]))
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
      |> element(~s(form[phx-value-key="checkout_flow"]))
      |> render_submit(%{"entry" => %{"value" => "control=50,bogus=50"}})

      assert TestRepo.get_by!(Entry, key: "checkout_flow").value == "control=90,new_flow=10"
    end

    test "the running total updates live as weights change", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/variant-flags")

      view |> element(~s(button[phx-value-key="checkout_flow"])) |> render_click()

      html =
        view
        |> element(~s(form[phx-value-key="checkout_flow"]))
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
