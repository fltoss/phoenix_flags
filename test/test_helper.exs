PhoenixFlags.TestRepo.start_link()
PhoenixFlags.TestEndpoint.start_link()

Ecto.Adapters.SQL.Sandbox.mode(PhoenixFlags.TestRepo, :manual)

ExUnit.start()
