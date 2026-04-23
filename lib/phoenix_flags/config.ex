defmodule PhoenixFlags.Config do
  @moduledoc """
  Configuration struct for a PhoenixFlags instance.

  Resolved from three sources (highest priority first):

  1. Runtime options passed to `start_link/1`
  2. Application environment (`config :my_app, MyApp.SystemConfig, ...`)
  3. Compile-time options passed to `use PhoenixFlags`
  """

  @enforce_keys [:otp_app, :repo, :name]
  defstruct [
    :otp_app,
    :repo,
    :name,
    :actor_fn,
    :encryptor,
    cache_enabled: true,
    audit: false
  ]

  @type t :: %__MODULE__{
          otp_app: atom(),
          repo: module(),
          name: module(),
          cache_enabled: boolean(),
          audit: boolean(),
          actor_fn: (term() -> String.t()) | nil,
          encryptor: module() | nil
        }

  @doc """
  Creates a new config struct from the given options.

  Raises on missing required keys.
  """
  def new!(opts) when is_list(opts) do
    opts = Map.new(opts)

    for key <- @enforce_keys do
      unless Map.has_key?(opts, key) do
        raise PhoenixFlags.Error, "missing required option :#{key} for PhoenixFlags"
      end
    end

    %__MODULE__{
      otp_app: opts[:otp_app],
      repo: opts[:repo],
      name: opts[:name],
      cache_enabled: Map.get(opts, :cache_enabled, true),
      audit: Map.get(opts, :audit, false),
      actor_fn: Map.get(opts, :actor_fn),
      encryptor: Map.get(opts, :encryptor)
    }
  end
end
