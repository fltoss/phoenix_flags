import Config

if config_env() == :test do
  config :phoenix_flags, PhoenixFlags.TestRepo,
    username: System.get_env("POSTGRES_USER", "postgres"),
    password: System.get_env("POSTGRES_PASSWORD", "postgres"),
    hostname: System.get_env("DB_HOST", "localhost"),
    database: "phoenix_flags_test#{System.get_env("MIX_TEST_PARTITION")}",
    pool: Ecto.Adapters.SQL.Sandbox,
    pool_size: System.schedulers_online() * 2

  config :phoenix_flags, ecto_repos: [PhoenixFlags.TestRepo]

  config :logger, level: :warning
end
