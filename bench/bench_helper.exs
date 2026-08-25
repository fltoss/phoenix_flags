# Suppress Ecto debug logs during benchmarks
Logger.configure(level: :warning)

# Compile test support modules needed for benchmarks
Code.require_file("test/support/test_repo.ex")

# Benchmarks get their own database. They run outside the Ecto sandbox, so their
# writes commit -- pointing them at phoenix_flags_test left rows behind that
# broke the next `mix test` run.
database = System.get_env("BENCH_DATABASE", "phoenix_flags_bench")

repo_config = [
  username: System.get_env("POSTGRES_USER", "postgres"),
  password: System.get_env("POSTGRES_PASSWORD", "postgres"),
  hostname: System.get_env("DB_HOST", "localhost"),
  database: database,
  pool_size: 10
]

Application.put_env(:phoenix_flags, PhoenixFlags.TestRepo, repo_config)

case Ecto.Adapters.Postgres.storage_up(repo_config) do
  :ok -> IO.puts("bench: created database #{database}")
  {:error, :already_up} -> :ok
  {:error, reason} -> raise "bench: could not create #{database}: #{inspect(reason)}"
end

{:ok, _} = PhoenixFlags.TestRepo.start_link()

Ecto.Migrator.run(PhoenixFlags.TestRepo, "priv/test_repo/migrations", :up, all: true, log: false)

# Clean up any stale entries from previous runs.
PhoenixFlags.TestRepo.delete_all(PhoenixFlags.Target)
PhoenixFlags.TestRepo.delete_all(PhoenixFlags.Entry)
