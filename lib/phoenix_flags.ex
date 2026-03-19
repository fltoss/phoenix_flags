defmodule PhoenixFlags do
  @moduledoc """
  Database-backed, cached, cluster-aware system configuration for Phoenix.

  ## Usage

  Define a configuration module in your application:

      defmodule MyApp.SystemConfig do
        use PhoenixFlags,
          otp_app: :my_app,
          repo: MyApp.Repo

        def benefits_enabled?, do: get("enable_benefits", false)
      end

  Add it to your supervision tree:

      children = [
        MyApp.Repo,
        MyApp.SystemConfig,
        # ...
      ]

  Read configuration values:

      MyApp.SystemConfig.get("enable_benefits")        #=> true
      MyApp.SystemConfig.get("max_retries", 3)         #=> 3
      MyApp.SystemConfig.benefits_enabled?()            #=> true

  ## Testing

  In test environment, a `Test` submodule is generated with process-scoped overrides:

      MyApp.SystemConfig.Test.put_override("enable_benefits", true)
      MyApp.SystemConfig.Test.insert_entry("enable_benefits", true)

  ## Architecture

  - **Storage**: `system_flags` table in PostgreSQL (source of truth)
  - **Cache**: Single `:persistent_term` key holding a pre-built `%{key => value}` map
  - **Reads**: `:persistent_term.get` + `Map.get` — zero-copy, no process calls
  - **Writes**: GenServer updates DB, reloads local cache, notifies peer nodes
  - **Cluster**: After a write, the GenServer sends `:reload` to its counterpart
    on all connected nodes — no PubSub dependency
  """

  @doc """
  Declares a flag. Validated at compile time.

      flag "enable_benefits",
        type: :boolean,
        default: "false",
        category: "integrations",
        label: "Enable Benefits",
        description: "When enabled, the Benefits integration is active."
  """
  defmacro flag(key, opts) do
    quote do
      @phoenix_flags PhoenixFlags.Flag.new!(Keyword.put(unquote(opts), :key, unquote(key)))
    end
  end

  @doc false
  defmacro __before_compile__(_env) do
    quote do
      @doc """
      Returns the list of declared flags. Generated from `flag/2` macro calls.
      """
      def flags do
        @phoenix_flags |> Enum.reverse()
      end
    end
  end

  @doc false
  defmacro __using__(opts) do
    test_module = Module.concat([__CALLER__.module, Test])

    quote location: :keep do
      import PhoenixFlags, only: [flag: 2]

      @otp_app unquote(opts)[:otp_app] ||
                 raise(PhoenixFlags.Error, "missing :otp_app option for use PhoenixFlags")
      @repo unquote(opts)[:repo] ||
              raise(PhoenixFlags.Error, "missing :repo option for use PhoenixFlags")

      @doc false
      def child_spec(runtime_opts \\ []) do
        compile_opts = unquote(opts)
        env_opts = Application.get_env(@otp_app, __MODULE__, [])

        config =
          compile_opts
          |> Keyword.merge(env_opts)
          |> Keyword.merge(runtime_opts)
          |> Keyword.put(:name, __MODULE__)
          |> PhoenixFlags.Config.new!()

        %{
          id: __MODULE__,
          start: {PhoenixFlags.Server, :start_link, [config]},
          type: :worker
        }
      end

      @doc """
      Returns the cached value for a config key, cast to its native type.
      """
      def get(key, default \\ nil) do
        PhoenixFlags.Server.get(__MODULE__, key, default)
      end

      @doc """
      Updates a config entry and refreshes the cache across the cluster.

      Accepts an optional `:timeout` (in milliseconds, default `5000`).
      """
      def update_entry(key, attrs, opts \\ []) do
        PhoenixFlags.Server.update_entry(__MODULE__, key, attrs, opts)
      end

      @doc """
      Returns all config entries grouped by category.
      """
      def all_grouped do
        PhoenixFlags.Server.all_grouped(__MODULE__)
      end

      Module.register_attribute(__MODULE__, :phoenix_flags, accumulate: true)

      @before_compile PhoenixFlags

      defoverridable child_spec: 1

      if Mix.env() == :test do
        defmodule unquote(test_module) do
          @moduledoc """
          Test helpers for `#{inspect(unquote(__CALLER__.module))}`.

          Only compiled in the `:test` environment.
          """

          @parent unquote(__CALLER__.module)
          @repo unquote(opts)[:repo]

          @doc """
          Sets a per-process config override. No DB writes, no race conditions.
          Safe for `async: true` tests.

              #{inspect(unquote(test_module))}.put_override("enable_benefits", true)
          """
          def put_override(key, value) do
            PhoenixFlags.Testing.put_override(@parent, key, value)
          end

          @doc """
          Inserts or updates a config entry in the database. Use this for LiveView
          and integration tests where the config is read in a different process.

              #{inspect(unquote(test_module))}.insert_entry("enable_benefits", true)
          """
          def insert_entry(key, value, opts \\ []) do
            PhoenixFlags.Testing.insert_entry(@repo, key, value, opts)
          end
        end
      end
    end
  end
end
