defmodule PhoenixFlags.Reader do
  @moduledoc false

  # The read path. Reads must not take the caller down: a missing instance, a
  # malformed opts or an unusable identity falls back to the default.
  #
  # Cached, a read is a :persistent_term lookup. Uncached (tests), a stub in
  # the process wins, then a rule, then the row.

  alias PhoenixFlags.Cache
  alias PhoenixFlags.Config
  alias PhoenixFlags.Context
  alias PhoenixFlags.Entry
  alias PhoenixFlags.Targeting
  alias PhoenixFlags.Testing
  alias PhoenixFlags.Values
  alias PhoenixFlags.Variant

  require Logger

  # After every declared flag, rather than ahead of them, which nil would sort.
  @undeclared_position 999_999

  def get(instance, key, default, opts) do
    case Cache.config(instance) do
      {:ok, %{cache_enabled: true}} ->
        case targeted(instance, key, opts) do
          {:ok, value} -> value
          :none -> instance |> Cache.values() |> Map.get(key, default) |> reject_variant(key)
        end

      {:ok, config} ->
        config |> get_uncached(instance, key, default, opts) |> reject_variant(key)

      :error ->
        default
    end
  end

  def variant(instance, key, identity, opts) do
    case assign(instance, key, identity, opts) do
      nil -> option(opts, :default, nil)
      assigned -> emit_assigned(assigned, instance, key, identity, opts)
    end
  rescue
    error ->
      # An unusable identity is a data condition as often as a coding one -- an
      # anonymous visitor, a record with no id -- so warn and fall back.
      # Variant.assign/4 stays strict for direct callers.
      Logger.warning(
        "PhoenixFlags: variant assignment failed for #{inspect(key)}: " <>
          Exception.message(error)
      )

      option(opts, :default, nil)
  end

  def all_grouped(instance) do
    case Cache.config(instance) do
      {:ok, config} ->
        order = Cache.order(instance)
        position = &Map.get(order, &1.key, @undeclared_position)

        config
        |> entries(instance)
        |> Enum.sort_by(position)
        |> Enum.group_by(& &1.category)
        |> Enum.sort_by(fn {_category, [first | _]} -> position.(first) end)

      :error ->
        []
    end
  end

  defp entries(%Config{cache_enabled: true}, instance), do: Cache.entries(instance)
  defp entries(%Config{} = config, _instance), do: config.repo.all(Entry)

  # A :variant flag holds a split, not a value, so reading it with get/3 is
  # always a mistake. Benchmarked at ~0ns against the bare read, so it is
  # guarded here -- one place, covering every caller.
  defp reject_variant(%Variant{}, key) do
    raise PhoenixFlags.Error,
          "#{inspect(key)} is a :variant flag and has no single value. " <>
            "Read it with variant(#{inspect(key)}, identity) instead of get/2."
  end

  defp reject_variant(value, _key), do: value

  defp get_uncached(config, instance, key, default, opts) do
    with :none <- Testing.get_stub(instance, key),
         :none <- targeted(instance, key, opts) do
      read_row(config, key, default)
    else
      {:ok, value} -> value
    end
  end

  defp assign(instance, key, identity, opts) do
    case Cache.config(instance) do
      {:ok, %{cache_enabled: true}} ->
        targeted_or(instance, key, opts, fn ->
          instance |> Cache.values() |> Map.get(key) |> assign_from(key, identity, opts)
        end)

      {:ok, config} ->
        assign_uncached(config, instance, key, identity, opts)

      :error ->
        nil
    end
  end

  # A stub names a variant directly rather than a split to assign from.
  defp assign_uncached(config, instance, key, identity, opts) do
    case Testing.get_stub(instance, key) do
      {:ok, stubbed} ->
        stubbed

      :none ->
        targeted_or(instance, key, opts, fn ->
          config |> read_variant(key) |> assign_from(key, identity, opts)
        end)
    end
  end

  # A rule pins the caller to a named arm, overriding the split: "force this
  # for them" would mean little otherwise.
  defp targeted_or(instance, key, opts, otherwise) do
    case targeted(instance, key, opts) do
      {:ok, targeted} -> targeted
      :none -> otherwise.()
    end
  end

  defp targeted(instance, key, opts) do
    instance |> Cache.targets() |> Targeting.resolve(key, fn -> context(opts) end)
  end

  defp context(opts) do
    case option(opts, :context, nil) do
      context when is_map(context) -> context
      context when is_list(context) -> Map.new(context)
      _absent -> Context.get()
    end
  end

  defp assign_from(%Variant{} = variant, key, identity, opts),
    do: Variant.assign(variant, key, identity, opts)

  defp assign_from(_other, _key, _identity, _opts), do: nil

  defp read_row(%Config{}, key, default) when not is_binary(key), do: default

  defp read_row(%Config{} = config, key, default) do
    case config.repo.get_by(Entry, key: key) do
      # Through the same decoding as the cache, or a secret would come back as
      # its ciphertext.
      %Entry{} = entry -> Values.decode(entry, config)
      nil -> default
    end
  rescue
    DBConnection.OwnershipError ->
      default

    error ->
      Logger.warning("PhoenixFlags: fallback read failed for #{inspect(key)}: #{inspect(error)}")
      default
  end

  defp read_variant(%Config{}, key) when not is_binary(key), do: nil

  defp read_variant(%Config{} = config, key) do
    case config.repo.get_by(Entry, key: key) do
      %Entry{type: "variant"} = entry -> Values.decode(entry, config)
      _other -> nil
    end
  rescue
    DBConnection.OwnershipError ->
      nil

    error ->
      Logger.warning("PhoenixFlags: variant read failed for #{inspect(key)}: #{inspect(error)}")
      nil
  end

  defp emit_assigned(assigned, instance, key, identity, opts) do
    if option(opts, :telemetry, false) do
      :telemetry.execute(
        [:phoenix_flags, :variant, :assigned],
        %{},
        %{instance: instance, flag: key, identity: identity, variant: assigned}
      )
    end

    assigned
  end

  # Every option read on this path tolerates a non-keyword opts: the rescue in
  # variant/4 must not itself be able to raise.
  defp option(opts, key, default) when is_list(opts), do: Keyword.get(opts, key, default)
  defp option(_opts, _key, default), do: default
end
