defmodule PhoenixFlags.SecretTest do
  use PhoenixFlags.DataCase

  alias PhoenixFlags.AuditLog
  alias PhoenixFlags.Config
  alias PhoenixFlags.Entry
  alias PhoenixFlags.Server

  defmodule Encryptor do
    def encrypt(plaintext) when is_binary(plaintext), do: String.reverse(plaintext)
    def decrypt(ciphertext) when is_binary(ciphertext), do: String.reverse(ciphertext)
  end

  defmodule SecretConfig do
    use PhoenixFlags,
      otp_app: :phoenix_flags,
      repo: PhoenixFlags.TestRepo,
      encryptor: PhoenixFlags.SecretTest.Encryptor

    flag("api_key",
      type: :secret,
      category: "ai",
      label: "API Key"
    )
  end

  defmodule AuditedSecretConfig do
    use PhoenixFlags,
      otp_app: :phoenix_flags,
      repo: PhoenixFlags.TestRepo,
      encryptor: PhoenixFlags.SecretTest.Encryptor

    flag("api_key",
      type: :secret,
      category: "ai",
      label: "API Key"
    )
  end

  defmodule SeededSecretConfig do
    use PhoenixFlags,
      otp_app: :phoenix_flags,
      repo: PhoenixFlags.TestRepo,
      encryptor: PhoenixFlags.SecretTest.Encryptor

    flag("api_key",
      type: :secret,
      default: "seeded-secret",
      category: "ai",
      label: "API Key"
    )
  end

  defmodule ErrorReturningEncryptor do
    def encrypt(plaintext) when is_binary(plaintext), do: String.reverse(plaintext)
    def decrypt(_ciphertext), do: :error
  end

  defp cleanup_persistent_term(module) do
    on_exit(fn ->
      for key <- [:cache, :config, :order] do
        try do
          :persistent_term.erase({PhoenixFlags, module, key})
        rescue
          ArgumentError -> :ok
        end
      end
    end)
  end

  defp start_cached!(module) do
    config = %Config{
      otp_app: :phoenix_flags,
      repo: TestRepo,
      name: module,
      cache_enabled: true,
      encryptor: Encryptor
    }

    start_supervised!({Server, config})
    cleanup_persistent_term(module)
    config
  end

  describe "encryption round-trip" do
    setup do
      start_cached!(SecretConfig)
      :ok
    end

    test "stores ciphertext in the DB and returns plaintext from get/2" do
      {:ok, _} = SecretConfig.update_entry("api_key", %{"value" => "sk-secret-123"})

      entry = TestRepo.get_by!(Entry, key: "api_key")
      assert entry.value == "321-terces-ks", "expected encrypted (reversed) value in DB"

      assert SecretConfig.get("api_key") == "sk-secret-123"
    end

    test "empty string is stored and returned as-is (never encrypted)" do
      {:ok, _} = SecretConfig.update_entry("api_key", %{"value" => ""})

      entry = TestRepo.get_by!(Entry, key: "api_key")
      assert entry.value == ""
      assert SecretConfig.get("api_key") == nil
    end

    test "all_grouped returns ciphertext in entry.value (never plaintext)" do
      {:ok, _} = SecretConfig.update_entry("api_key", %{"value" => "sk-secret-123"})

      [{"ai", [entry]}] = SecretConfig.all_grouped()

      assert entry.type == "secret"
      assert entry.value == "321-terces-ks"
      refute entry.value == "sk-secret-123"
    end

    test "restart rebuilds plaintext cache from ciphertext in DB" do
      {:ok, _} = SecretConfig.update_entry("api_key", %{"value" => "sk-restart"})
      assert SecretConfig.get("api_key") == "sk-restart"

      stop_supervised!(PhoenixFlags.Server)

      start_supervised!(
        {Server,
         %Config{
           otp_app: :phoenix_flags,
           repo: TestRepo,
           name: SecretConfig,
           cache_enabled: true,
           encryptor: Encryptor
         }}
      )

      assert SecretConfig.get("api_key") == "sk-restart"
    end
  end

  describe "seeding" do
    test "a non-empty secret default is encrypted before it reaches the database" do
      start_cached!(SeededSecretConfig)

      entry = TestRepo.get_by!(Entry, key: "api_key")
      assert entry.value == "terces-dedees", "expected encrypted (reversed) default in DB"
      refute entry.value == "seeded-secret"

      assert SeededSecretConfig.get("api_key") == "seeded-secret"
    end
  end

  describe "uncached reads" do
    test "get/2 decrypts secrets when cache_enabled: false" do
      config = %Config{
        otp_app: :phoenix_flags,
        repo: TestRepo,
        name: SecretConfig,
        cache_enabled: false,
        encryptor: Encryptor
      }

      start_supervised!({Server, config})
      cleanup_persistent_term(SecretConfig)

      {:ok, _} = SecretConfig.update_entry("api_key", %{"value" => "sk-uncached"})

      entry = TestRepo.get_by!(Entry, key: "api_key")
      assert entry.value == "dehcacnu-ks", "expected ciphertext at rest"

      assert SecretConfig.get("api_key") == "sk-uncached"
    end
  end

  describe "decrypt failure handling" do
    test "a decrypt returning a non-binary yields nil, never the raw return value" do
      config = %Config{
        otp_app: :phoenix_flags,
        repo: TestRepo,
        name: SecretConfig,
        cache_enabled: true,
        encryptor: ErrorReturningEncryptor
      }

      start_supervised!({Server, config})
      cleanup_persistent_term(SecretConfig)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, _} = SecretConfig.update_entry("api_key", %{"value" => "sk-doomed"})
        end)

      assert log =~ "failed to decrypt secret api_key"
      refute SecretConfig.get("api_key") == :error
      assert SecretConfig.get("api_key") == nil
    end
  end

  describe "audit redaction" do
    setup do
      config = %Config{
        otp_app: :phoenix_flags,
        repo: TestRepo,
        name: AuditedSecretConfig,
        cache_enabled: true,
        audit: true,
        encryptor: Encryptor
      }

      start_supervised!({Server, config})
      cleanup_persistent_term(AuditedSecretConfig)

      :ok
    end

    test "records [redacted] for old and new secret values" do
      {:ok, _} = AuditedSecretConfig.update_entry("api_key", %{"value" => "first"})

      {:ok, _} =
        AuditedSecretConfig.update_entry("api_key", %{"value" => "second"}, actor: "alice")

      [oldest, newest] = TestRepo.all(AuditLog) |> Enum.sort_by(& &1.inserted_at)

      assert oldest.old_value == ""
      assert oldest.new_value == "[redacted]"

      assert newest.old_value == "[redacted]"
      assert newest.new_value == "[redacted]"
      assert newest.actor == "alice"
    end

    test "records empty string when a secret is cleared" do
      {:ok, _} = AuditedSecretConfig.update_entry("api_key", %{"value" => "will-be-cleared"})
      {:ok, _} = AuditedSecretConfig.update_entry("api_key", %{"value" => ""})

      [_set, clear] = TestRepo.all(AuditLog) |> Enum.sort_by(& &1.inserted_at)

      assert clear.old_value == "[redacted]"
      assert clear.new_value == ""
    end
  end

  describe "boot-time encryptor validation" do
    test "raises when a :secret flag module boots without an encryptor" do
      config = %Config{
        otp_app: :phoenix_flags,
        repo: TestRepo,
        name: SecretConfig,
        cache_enabled: true,
        encryptor: nil
      }

      assert_raise PhoenixFlags.Error, ~r/declares :secret flags but no :encryptor/, fn ->
        # Bypass the child_spec (which passes the compile-time encryptor) and
        # instantiate the server directly with a nil encryptor.
        PhoenixFlags.Server.init(config)
      end
    end

    test "raises when encryptor module does not export encrypt/1 + decrypt/1" do
      defmodule BadEncryptor do
        def something_else(x), do: x
      end

      config = %Config{
        otp_app: :phoenix_flags,
        repo: TestRepo,
        name: SecretConfig,
        cache_enabled: true,
        encryptor: BadEncryptor
      }

      assert_raise PhoenixFlags.Error, ~r/must export encrypt\/1 and decrypt\/1/, fn ->
        PhoenixFlags.Server.init(config)
      end
    end
  end

  describe "compile-time encryptor validation" do
    test "raises when a :secret flag is declared and :encryptor is omitted" do
      source = """
      defmodule PhoenixFlags.SecretTest.MissingEncryptor do
        use PhoenixFlags,
          otp_app: :phoenix_flags,
          repo: PhoenixFlags.TestRepo

        flag "api_key", type: :secret
      end
      """

      assert_raise PhoenixFlags.Error, ~r/declares :secret flags .* but no :encryptor/, fn ->
        Code.compile_string(source)
      end
    end

    test "compiles when :encryptor is provided" do
      source = """
      defmodule PhoenixFlags.SecretTest.WithEncryptor do
        use PhoenixFlags,
          otp_app: :phoenix_flags,
          repo: PhoenixFlags.TestRepo,
          encryptor: PhoenixFlags.SecretTest.Encryptor

        flag "api_key", type: :secret
      end
      """

      compiled = Code.compile_string(source)

      assert Enum.any?(compiled, fn {mod, _bin} ->
               mod == PhoenixFlags.SecretTest.WithEncryptor
             end)
    end
  end
end
