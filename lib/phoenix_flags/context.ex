defmodule PhoenixFlags.Context do
  @moduledoc """
  Process-scoped attributes used to evaluate targeting rules.

  Set it once where you already have the current user — a plug, or a LiveView
  `on_mount` hook — and every read in that process can then be targeted without
  threading a context through every call site:

      # lib/my_app_web/plugs/flag_context.ex
      def call(conn, _opts) do
        user = conn.assigns.current_user
        PhoenixFlags.Context.put(user_id: user.id, company_id: user.company_id)
        conn
      end

      # anywhere in the request
      MyApp.SystemConfig.get("enable_benefits", false)

  A context passed explicitly to a read wins over whatever is in the process:

      MyApp.SystemConfig.get("enable_benefits", false, context: %{company_id: 999})

  ## Scope

  This is the process dictionary, so it is scoped to one process and is **not**
  inherited by processes you spawn. A `Task.async/1`, a `GenServer.cast/2`, or a
  `spawn/1` starts with an empty context. Either set it again inside the process,
  or pass `:context` explicitly to those reads:

      context = PhoenixFlags.Context.get()

      Task.async(fn ->
        MyApp.SystemConfig.get("enable_benefits", false, context: context)
      end)

  ## Attribute keys and values

  Keys may be atoms or strings; `:company_id` and `"company_id"` are the same
  attribute. Values are compared as strings, so `123` matches a rule value of
  `"123"` — consistent with every flag value being stored as a string. See
  `PhoenixFlags.Target` for the matching rules.
  """

  @key {PhoenixFlags, :context}

  @type t :: %{optional(atom() | String.t()) => term()}

  @doc """
  Replaces the context for the current process.

  Accepts a map or a keyword list. Returns `:ok`.

      PhoenixFlags.Context.put(user_id: 7, company_id: 123)
      PhoenixFlags.Context.put(%{user_id: 7})
  """
  @spec put(t() | keyword()) :: :ok
  def put(attributes) when is_list(attributes) or is_map(attributes) do
    Process.put(@key, Map.new(attributes))

    :ok
  end

  @doc """
  Merges `attributes` into the context for the current process.

  Useful when the attributes become known at different points in a request —
  the account early, the feature-specific detail later.
  """
  @spec merge(t() | keyword()) :: :ok
  def merge(attributes) when is_list(attributes) or is_map(attributes) do
    Process.put(@key, Map.merge(get(), Map.new(attributes)))

    :ok
  end

  @doc """
  Returns the current process's context, or `%{}` if none is set.
  """
  @spec get() :: t()
  def get do
    case Process.get(@key) do
      context when is_map(context) -> context
      _other -> %{}
    end
  end

  @doc """
  Removes the context from the current process.

  Long-lived processes that handle work for different accounts should clear it
  between units of work, so a stale context cannot leak into the next one.
  """
  @spec clear() :: :ok
  def clear do
    Process.delete(@key)

    :ok
  end
end
