defmodule PhoenixFlags.AuditTest do
  use PhoenixFlags.DataCase

  alias PhoenixFlags.AuditLog
  alias PhoenixFlags.Config
  alias PhoenixFlags.Entry
  alias PhoenixFlags.Server

  defp start_server!(opts) do
    module_name = :"PhoenixFlags.AuditTest.Config#{System.unique_integer([:positive])}"
    audit = Keyword.get(opts, :audit, false)
    actor_fn = Keyword.get(opts, :actor_fn)

    flags =
      Keyword.get(opts, :flags, [
        %{key: "flag_a", type: "boolean", value: "true", category: "test", label: "Flag A"}
      ])

    Module.create(
      module_name,
      quote do
        def flags, do: unquote(Macro.escape(flags))
      end,
      Macro.Env.location(__ENV__)
    )

    config = %Config{
      otp_app: :phoenix_flags,
      repo: TestRepo,
      name: module_name,
      cache_enabled: false,
      audit: audit,
      actor_fn: actor_fn
    }

    start_supervised!({Server, config})

    {module_name, config}
  end

  describe "audit disabled (default)" do
    test "does not insert audit records on update" do
      {_module, config} = start_server!(audit: false)

      entry = TestRepo.get_by!(Entry, key: "flag_a")
      assert entry.value == "true"

      Server.update_entry(config.name, "flag_a", %{"value" => "false"}, actor: "admin")

      assert TestRepo.aggregate(AuditLog, :count) == 0
    end

    test "audit_log raises a clear error instead of a database error" do
      {module, _config} = start_server!(audit: false)

      assert_raise PhoenixFlags.Error, ~r/not configured with `audit: true`/, fn ->
        Server.audit_log(module)
      end

      assert_raise PhoenixFlags.Error, ~r/not configured with `audit: true`/, fn ->
        Server.audit_log(module, "flag_a")
      end
    end
  end

  describe "audit enabled" do
    test "inserts an audit record on successful update" do
      {_module, config} = start_server!(audit: true)

      Server.update_entry(config.name, "flag_a", %{"value" => "false"},
        actor: "admin@example.com"
      )

      logs = TestRepo.all(AuditLog)
      assert length(logs) == 1

      [log] = logs
      assert log.key == "flag_a"
      assert log.old_value == "true"
      assert log.new_value == "false"
      assert log.actor == "admin@example.com"
      assert log.inserted_at
    end

    test "records actor as unknown when no actor provided" do
      {_module, config} = start_server!(audit: true)

      Server.update_entry(config.name, "flag_a", %{"value" => "false"})

      [log] = TestRepo.all(AuditLog)
      assert log.actor == "unknown"
    end

    test "does not insert audit record on failed update" do
      {_module, config} = start_server!(audit: true)

      # Try to update with invalid value for boolean
      {:error, _changeset} =
        Server.update_entry(config.name, "flag_a", %{"value" => "invalid"}, actor: "admin")

      assert TestRepo.aggregate(AuditLog, :count) == 0
    end

    test "does not insert audit record for nonexistent key" do
      {_module, config} = start_server!(audit: true)

      {:error, :not_found} =
        Server.update_entry(config.name, "nonexistent", %{"value" => "false"}, actor: "admin")

      assert TestRepo.aggregate(AuditLog, :count) == 0
    end

    test "tracks multiple changes" do
      {_module, config} = start_server!(audit: true)

      Server.update_entry(config.name, "flag_a", %{"value" => "false"}, actor: "alice")
      Server.update_entry(config.name, "flag_a", %{"value" => "true"}, actor: "bob")

      logs = TestRepo.all(AuditLog)
      assert length(logs) == 2

      [first, second] = Enum.sort_by(logs, & &1.inserted_at)
      assert first.actor == "alice"
      assert first.old_value == "true"
      assert first.new_value == "false"

      assert second.actor == "bob"
      assert second.old_value == "false"
      assert second.new_value == "true"
    end
  end

  describe "audit_log queries" do
    test "audit_log/1 returns all entries newest first" do
      {_module, config} = start_server!(audit: true)

      Server.update_entry(config.name, "flag_a", %{"value" => "false"}, actor: "alice")
      Server.update_entry(config.name, "flag_a", %{"value" => "true"}, actor: "bob")

      logs = Server.audit_log(config.name)
      assert length(logs) == 2
      assert hd(logs).actor == "bob" || hd(logs).actor == "alice"
    end

    test "audit_log/2 filters by key" do
      {_module, config} =
        start_server!(
          audit: true,
          flags: [
            %{key: "flag_a", type: "boolean", value: "true", category: "test", label: "A"},
            %{key: "flag_b", type: "string", value: "hello", category: "test", label: "B"}
          ]
        )

      Server.update_entry(config.name, "flag_a", %{"value" => "false"}, actor: "alice")
      Server.update_entry(config.name, "flag_b", %{"value" => "world"}, actor: "bob")

      assert length(Server.audit_log(config.name, "flag_a")) == 1
      assert length(Server.audit_log(config.name, "flag_b")) == 1
      assert length(Server.audit_log(config.name)) == 2
    end
  end
end
