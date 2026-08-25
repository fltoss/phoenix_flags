# Minimal Phoenix dev server for manual testing.
#
# Usage:
#   mix run dev.exs
#
# Then visit http://localhost:4005/flags

Logger.configure(level: :debug)

# -- Config -------------------------------------------------------------------

Application.put_env(:phoenix_flags, PhoenixFlags.DevRepo,
  username: System.get_env("POSTGRES_USER", "postgres"),
  password: System.get_env("POSTGRES_PASSWORD", "postgres"),
  hostname: System.get_env("DB_HOST", "localhost"),
  database: "phoenix_flags_dev",
  pool_size: 5,
  show_sensitive_data_on_connection_error: true
)

Application.put_env(:phoenix_flags, PhoenixFlags.DevEndpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 4005],
  secret_key_base: String.duplicate("d", 64),
  server: true,
  live_view: [signing_salt: "pf_dev_salt"],
  render_errors: [formats: [html: PhoenixFlags.DevErrorHTML]],
  debug_errors: true,
  check_origin: false,
  watchers: []
)

Application.put_env(:phoenix, :serve_endpoints, true)

# -- Modules ------------------------------------------------------------------

defmodule PhoenixFlags.DevErrorHTML do
  def render(template, _assigns) do
    Phoenix.Controller.status_message_from_template(template)
  end
end

defmodule PhoenixFlags.DevRepo do
  use Ecto.Repo,
    otp_app: :phoenix_flags,
    adapter: Ecto.Adapters.Postgres
end

defmodule PhoenixFlags.DevConfig do
  use PhoenixFlags,
    otp_app: :phoenix_flags,
    repo: PhoenixFlags.DevRepo,
    audit: true,
    actor_fn: fn _socket -> "dev@localhost" end

  flag("enable_benefits",
    type: :boolean,
    default: "false",
    category: "integrations",
    label: "Enable Benefits",
    description: "When enabled, the Benefits integration is active."
  )

  flag("max_retries",
    type: :integer,
    default: "3",
    category: "reliability",
    label: "Max Retries",
    description: "Maximum number of retry attempts for failed operations."
  )

  flag("maintenance_mode",
    type: :boolean,
    default: "false",
    category: "operations",
    label: "Maintenance Mode",
    description: "When enabled, shows a maintenance page to users."
  )

  flag("api_rate_limit",
    type: :integer,
    default: "100",
    category: "reliability",
    label: "API Rate Limit",
    description: "Requests per minute per client."
  )

  flag("feature_tier",
    type: :select,
    default: "basic",
    category: "product",
    label: "Default Feature Tier",
    options: [{"Basic", "basic"}, {"Pro", "pro"}, {"Enterprise", "enterprise"}]
  )

  flag("checkout_flow",
    type: :variant,
    category: "experiments",
    label: "Checkout Flow Experiment",
    description: "Which checkout implementation a given user sees.",
    variants: [{"Control", "control", 90}, {"New flow", "new_flow", 10}]
  )

  flag("banner_copy",
    type: :variant,
    category: "experiments",
    label: "Banner Copy (24h TTL)",
    description: "Re-rolled once a day per visitor.",
    ttl: :timer.hours(24),
    variants: [{"Friendly", "friendly", 34}, {"Direct", "direct", 33}, {"Urgent", "urgent", 33}]
  )

  flag("discount_pct",
    type: :percentage,
    default: "0",
    category: "product",
    label: "Global Discount",
    description: "Applied to all new subscriptions."
  )
end

defmodule PhoenixFlags.DevRouter do
  use Phoenix.Router

  import Phoenix.LiveView.Router
  import PhoenixFlags.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
  end

  scope "/" do
    pipe_through(:browser)

    flags_dashboard("/", config: PhoenixFlags.DevConfig, app_js: "/dev/app.js")
  end
end

defmodule PhoenixFlags.DevAppJs do
  @moduledoc false
  @behaviour Plug

  # Build a minimal JS bundle from Phoenix + LiveView deps
  @phoenix_js File.read!(Path.join(:code.priv_dir(:phoenix), "static/phoenix.min.js"))
  @lv_js File.read!(
           Path.join(:code.priv_dir(:phoenix_live_view), "static/phoenix_live_view.min.js")
         )

  # The bundle below depends on these being esbuild IIFEs that bind a specific
  # name. If an upstream release renames the global or changes format, fail here
  # rather than shipping a dashboard that renders but never responds.
  for {name, js} <- [{"Phoenix", @phoenix_js}, {"LiveView", @lv_js}] do
    unless String.starts_with?(js, "var #{name}=") or String.starts_with?(js, "var #{name} =") do
      raise """
      dev.exs expected the bundled asset to begin with `var #{name}=`, but it starts with:

          #{String.slice(js, 0, 80)}

      The inline bundle in PhoenixFlags.DevAppJs relies on that binding.
      Update it to match however the dependency now exposes its entry point.
      """
    end
  end

  # Both bundles are esbuild IIFEs of the form `var Phoenix = (() => {...})()`,
  # so inside this wrapper arrow function those are ordinary function-scoped
  # locals -- NOT globals. Referencing them as `window.Phoenix` / `window.LiveView`
  # therefore reads undefined and no LiveSocket is ever created, which leaves the
  # dashboard rendered but completely inert.
  @bundle """
  (() => {
  #{@phoenix_js}
  #{@lv_js}
  let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content");
  let liveSocket = new LiveView.LiveSocket("/live", Phoenix.Socket, {params: {_csrf_token: csrfToken}});
  liveSocket.connect();
  window.liveSocket = liveSocket;
  })();
  """

  @impl true
  def init(_opts), do: []

  @impl true
  def call(conn, _opts) do
    conn
    |> Plug.Conn.put_resp_header("content-type", "application/javascript")
    |> Plug.Conn.send_resp(200, @bundle)
    |> Plug.Conn.halt()
  end
end

defmodule PhoenixFlags.DevEndpoint do
  use Phoenix.Endpoint, otp_app: :phoenix_flags

  @session_options [
    store: :cookie,
    key: "_pf_dev_key",
    signing_salt: "pf_dev_salt",
    same_site: "Lax"
  ]

  socket("/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]
  )

  plug(:match_dev_js)

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(Plug.Session, @session_options)
  plug(PhoenixFlags.DevRouter)

  defp match_dev_js(%{path_info: ["dev", "app.js"]} = conn, _opts) do
    PhoenixFlags.DevAppJs.call(conn, [])
  end

  defp match_dev_js(conn, _opts), do: conn
end

# -- Boot ---------------------------------------------------------------------

IO.puts("\n--- Starting PhoenixFlags dev server ---\n")

# Create DB if needed (before starting the repo connection pool)
PhoenixFlags.DevRepo.__adapter__().storage_up(
  Application.get_env(:phoenix_flags, PhoenixFlags.DevRepo)
)

{:ok, _} = PhoenixFlags.DevRepo.start_link()

Ecto.Migrator.run(PhoenixFlags.DevRepo, "priv/test_repo/migrations", :up, all: true)

# Start config server (seeds flags + loads cache)
%{start: {mod, fun, args}} = PhoenixFlags.DevConfig.child_spec()
{:ok, _} = apply(mod, fun, args)

# A sample targeting rule, so the dialog has something to show. Must come after
# the server starts -- put_target/2 needs the running instance's config.
# See it apply with: PhoenixFlags.put_context(company_id: 123)
if PhoenixFlags.DevConfig.targets("enable_benefits") == [] do
  PhoenixFlags.DevConfig.put_target("enable_benefits",
    conditions: [[attribute: :company_id, operator: :in, values: [123, 456]]],
    value: "true"
  )
end

# Start the endpoint
{:ok, _} = PhoenixFlags.DevEndpoint.start_link()

url = "http://localhost:4005"

IO.puts("""

  Dashboard: #{url}

  Restart the server after code changes.
  Press Ctrl+C twice to stop.
""")

case :os.type() do
  {:unix, :darwin} -> System.cmd("open", [url])
  {:unix, _} -> System.cmd("xdg-open", [url])
  {:win32, _} -> System.cmd("cmd", ["/c", "start", url])
end

Process.sleep(:infinity)
