defmodule PhoenixFlags.ConfigTest do
  use ExUnit.Case, async: true

  alias PhoenixFlags.Config

  @valid_opts [otp_app: :phoenix_flags, repo: PhoenixFlags.TestRepo, name: SomeModule]

  describe "new!/1" do
    test "builds a config with defaults" do
      config = Config.new!(@valid_opts)

      assert config.cache_enabled == true
      assert config.audit == false
      assert config.refresh_interval == 60_000
    end

    test "raises on missing required keys" do
      assert_raise PhoenixFlags.Error, ~r/missing required option :repo/, fn ->
        Config.new!(otp_app: :phoenix_flags, name: SomeModule)
      end
    end

    test "raises on unknown options instead of silently ignoring them" do
      assert_raise PhoenixFlags.Error, ~r/unknown option\(s\) \[:audit_enabled\]/, fn ->
        Config.new!(@valid_opts ++ [audit_enabled: true])
      end
    end

    test "accepts refresh_interval: false to disable the periodic refresh" do
      config = Config.new!(@valid_opts ++ [refresh_interval: false])

      assert config.refresh_interval == false
    end

    test "raises on an invalid refresh_interval" do
      assert_raise PhoenixFlags.Error, ~r/:refresh_interval must be a positive integer/, fn ->
        Config.new!(@valid_opts ++ [refresh_interval: -5])
      end
    end
  end
end
