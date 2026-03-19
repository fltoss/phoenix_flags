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
    table: "system_flags",
    cache_enabled: true
  ]

  @type t :: %__MODULE__{
          otp_app: atom(),
          repo: module(),
          name: module(),
          table: String.t(),
          cache_enabled: boolean()
        }

  @doc """
  Creates a new config struct from the given options.

  Raises on missing required keys.
  """
  def new!(opts) when is_list(opts) do
    opts = Map.new(opts)

    %__MODULE__{
      otp_app: Map.fetch!(opts, :otp_app),
      repo: Map.fetch!(opts, :repo),
      name: Map.fetch!(opts, :name),
      table: Map.get(opts, :table, "system_flags"),
      cache_enabled: Map.get(opts, :cache_enabled, true)
    }
  end
end
