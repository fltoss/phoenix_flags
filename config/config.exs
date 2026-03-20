import Config

if config_env() == :test do
  config :logger, level: :warning

  config :phoenix_flags, PhoenixFlags.TestRepo,
    username: System.get_env("POSTGRES_USER", "postgres"),
    password: System.get_env("POSTGRES_PASSWORD", "postgres"),
    hostname: System.get_env("DB_HOST", "localhost"),
    database: "phoenix_flags_test#{System.get_env("MIX_TEST_PARTITION")}",
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: System.schedulers_online() * 2

  config :phoenix_flags, ecto_repos: [PhoenixFlags.TestRepo]

  config :phoenix_flags, PhoenixFlags.TestEndpoint,
    http: [ip: {127, 0, 0, 1}, port: 4099],
    secret_key_base: String.duplicate("a", 64),
    server: false,
    live_view: [signing_salt: "pf_test_signing_salt"],
    render_errors: [formats: [html: PhoenixFlags.TestErrorHTML]]

  if Code.ensure_loaded?(PhoenixTest) do
    config :phoenix_test, :endpoint, PhoenixFlags.TestEndpoint
  end
end
