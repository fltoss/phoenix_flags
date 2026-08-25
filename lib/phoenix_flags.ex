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

      MyApp.SystemConfig.Test.stub("enable_benefits", true)
      MyApp.SystemConfig.Test.insert_entry("enable_benefits", true)

  ## Architecture

  - **Storage**: `system_flags` table in PostgreSQL (source of truth)
  - **Cache**: Single `:persistent_term` key holding a pre-built `%{key => value}` map
  - **Reads**: `:persistent_term.get` + `Map.get` — zero-copy, no process calls
  - **Writes**: GenServer updates DB, reloads local cache, notifies peer nodes
  - **Cluster**: After a write, the GenServer sends `:reload` to its counterpart
    on all connected nodes — no PubSub dependency. A periodic jittered cache
    refresh (`refresh_interval`, default 60s) heals nodes that missed a
    notification.
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
  defmacro __before_compile__(env) do
    validate_encryptor_present!(env)

    quote do
      @doc """
      Returns the list of declared flags. Generated from `flag/2` macro calls.
      """
      def flags do
        @phoenix_flags |> Enum.reverse()
      end

      @doc """
      Returns `{label, value}` options for a `:select` flag, or `[]` if not a select.
      """
      def select_options(key) do
        case Enum.find(flags(), &(&1.key == key)) do
          %PhoenixFlags.Flag{options: options} when is_list(options) -> options
          _ -> []
        end
      end

      @doc """
      Returns the declared `{label, value, weight}` variants for a `:variant`
      flag, or `[]` if the key is not a variant flag.

      These are the *declared* weights. The live split is whatever is stored in
      the database, which the dashboard can change at runtime.
      """
      def variants(key) do
        case Enum.find(flags(), &(&1.key == key)) do
          %PhoenixFlags.Flag{type: :variant, variants: variants} when is_list(variants) ->
            variants

          _ ->
            []
        end
      end
    end
  end

  # `:secret` flags are meaningless without an encryptor, and the failure would
  # otherwise only surface at runtime on the first read.
  defp validate_encryptor_present!(env) do
    declared_flags = Module.get_attribute(env.module, :phoenix_flags) || []
    encryptor_set? = Module.get_attribute(env.module, :phoenix_flags_encryptor_set?) || false
    secret_flags = for flag <- declared_flags, flag.type == :secret, do: flag.key

    if secret_flags != [] and not encryptor_set? do
      raise PhoenixFlags.Error,
            "#{inspect(env.module)} declares :secret flags #{inspect(secret_flags)} but no :encryptor was passed to `use PhoenixFlags`. " <>
              "Add `encryptor: MyApp.MyEncryptor` (a module exporting encrypt/1 and decrypt/1) or remove the :secret flags."
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

      @phoenix_flags_encryptor_set? Keyword.has_key?(unquote(opts), :encryptor)

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

      Raises for a `:variant` flag, which holds a split rather than a single
      value — use `variant/3` for those.
      """
      def get(key, default \\ nil) do
        PhoenixFlags.Server.get(__MODULE__, key, default)
      end

      @doc """
      Returns the variant assigned to `identity` for a `:variant` flag.

      Deterministic: the same identity always gets the same variant, on every
      node and across restarts. Does no database or process work.

          MyApp.SystemConfig.variant("checkout_flow", user.id)
          #=> "new_flow"

      Options: `:default` (when the flag is missing or not a variant flag),
      `:telemetry` (emit an exposure event), `:now` (for testing TTL rollover).
      See `PhoenixFlags.Server.variant/4` and `PhoenixFlags.Variant`.
      """
      def variant(key, identity, opts \\ []) do
        PhoenixFlags.Server.variant(__MODULE__, key, identity, opts)
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

      @doc """
      Returns all audit log entries, newest first.

      Raises `PhoenixFlags.Error` unless `audit: true` is set.
      """
      def audit_log do
        PhoenixFlags.Server.audit_log(__MODULE__)
      end

      @doc """
      Returns audit log entries for a specific flag key, newest first.

      Raises `PhoenixFlags.Error` unless `audit: true` is set.
      """
      def audit_log(key) do
        PhoenixFlags.Server.audit_log(__MODULE__, key)
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

              #{inspect(unquote(test_module))}.stub("enable_benefits", true)
          """
          def stub(key, value) do
            PhoenixFlags.Testing.stub(@parent, key, value)
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
