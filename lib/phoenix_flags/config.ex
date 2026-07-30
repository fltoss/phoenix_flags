defmodule PhoenixFlags.Config do
  @moduledoc """
  Configuration struct for a PhoenixFlags instance.

  Resolved from three sources (highest priority first):

  1. Runtime options passed to `start_link/1`
  2. Application environment (`config :my_app, MyApp.SystemConfig, ...`)
  3. Compile-time options passed to `use PhoenixFlags`

  ## Options

  - `:otp_app` (required) — the OTP application to read environment config from
  - `:repo` (required) — the Ecto repo used for storage
  - `:name` (required, set automatically) — the module that `use PhoenixFlags`
  - `:cache_enabled` — cache values in `:persistent_term` (default `true`);
    disable in tests for Ecto sandbox compatibility
  - `:audit` — record value changes in the audit table (default `false`)
  - `:actor_fn` — 1-arity function resolving the audit actor from a socket/conn
  - `:encryptor` — module exporting `encrypt/1` and `decrypt/1`, required for
    `:secret` flags
  - `:refresh_interval` — how often (in milliseconds) the cache is reloaded
    from the database to heal missed cluster notifications (default `60_000`);
    set to `false` to disable the periodic refresh
  """

  @enforce_keys [:otp_app, :repo, :name]
  defstruct [
    :otp_app,
    :repo,
    :name,
    :actor_fn,
    :encryptor,
    cache_enabled: true,
    audit: false,
    refresh_interval: 60_000
  ]

  @known_keys [
    :otp_app,
    :repo,
    :name,
    :actor_fn,
    :encryptor,
    :cache_enabled,
    :audit,
    :refresh_interval
  ]

  @type t :: %__MODULE__{
          otp_app: atom(),
          repo: module(),
          name: module(),
          cache_enabled: boolean(),
          audit: boolean(),
          actor_fn: (term() -> String.t()) | nil,
          encryptor: module() | nil,
          refresh_interval: pos_integer() | false
        }

  @doc """
  Creates a new config struct from the given options.

  Raises on missing required keys and on unknown keys — a silently ignored
  typo like `audit_enabled: true` would leave a security-relevant feature
  switched off.
  """
  def new!(opts) when is_list(opts) do
    opts = Map.new(opts)

    for key <- @enforce_keys do
      unless Map.has_key?(opts, key) do
        raise PhoenixFlags.Error, "missing required option :#{key} for PhoenixFlags"
      end
    end

    case Map.keys(opts) -- @known_keys do
      [] ->
        :ok

      unknown ->
        raise PhoenixFlags.Error,
              "unknown option(s) #{inspect(unknown)} for PhoenixFlags. " <>
                "Valid options are: #{inspect(@known_keys)}"
    end

    %__MODULE__{
      otp_app: opts[:otp_app],
      repo: opts[:repo],
      name: opts[:name],
      cache_enabled: Map.get(opts, :cache_enabled, true),
      audit: Map.get(opts, :audit, false),
      actor_fn: Map.get(opts, :actor_fn),
      encryptor: Map.get(opts, :encryptor),
      refresh_interval: validate_refresh_interval!(Map.get(opts, :refresh_interval, 60_000))
    }
  end

  defp validate_refresh_interval!(interval)
       when interval == false or (is_integer(interval) and interval > 0),
       do: interval

  defp validate_refresh_interval!(other) do
    raise PhoenixFlags.Error,
          ":refresh_interval must be a positive integer (milliseconds) or false, " <>
            "got: #{inspect(other)}"
  end
end
