# Suppress Ecto debug logs during benchmarks
Logger.configure(level: :warning)

# Compile test support modules needed for benchmarks
Code.require_file("test/support/test_repo.ex")

# Configure the test repo for benchmarks (uses same DB as tests)
Application.put_env(:phoenix_flags, PhoenixFlags.TestRepo,
  username: System.get_env("POSTGRES_USER", "postgres"),
  password: System.get_env("POSTGRES_PASSWORD", "postgres"),
  hostname: System.get_env("DB_HOST", "localhost"),
  database: "phoenix_flags_test",
  pool_size: 10
)

# Start the repo
{:ok, _} = PhoenixFlags.TestRepo.start_link()

# Clean up any stale entries from previous runs
PhoenixFlags.TestRepo.delete_all(PhoenixFlags.Entry)
