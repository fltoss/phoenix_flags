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
      {:ok, config} -> read(config, instance, key, default, opts)
      :error -> default
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

  defp read(%Config{cache_enabled: true} = config, instance, key, default, opts) do
    case targeted(config, instance, key, opts) do
      {:ok, value, type} -> forced(value, type, key)
      :none -> instance |> Cache.values() |> stored(key, default) |> reject_variant(key)
    end
  end

  defp read(%Config{} = config, instance, key, default, opts) do
    with :none <- Testing.get_stub(instance, key),
         :none <- targeted(config, instance, key, opts) do
      config |> read_row(key, default) |> reject_variant(key)
    else
      {:ok, value} -> value
      {:ok, value, type} -> forced(value, type, key)
    end
  end

  # A value that failed to cast or decrypt is cached as nil; the caller's
  # default is a better answer than a nil they did not ask for.
  defp stored(values, key, default) do
    case Map.fetch(values, key) do
      {:ok, nil} -> default
      {:ok, value} -> value
      :error -> default
    end
  end

  defp forced(_value, "variant", key), do: variant_has_no_value!(key)
  defp forced(value, _type, _key), do: value

  # A :variant flag holds a split, not a value, so reading it with get/3 is
  # always a mistake -- targeted or not. Benchmarked at ~0ns against the bare
  # read, so it is guarded here, one place covering every caller.
  defp reject_variant(%Variant{}, key), do: variant_has_no_value!(key)
  defp reject_variant(value, _key), do: value

  defp variant_has_no_value!(key) do
    raise PhoenixFlags.Error,
          "#{inspect(key)} is a :variant flag and has no single value. " <>
            "Read it with variant(#{inspect(key)}, identity) instead of get/2."
  end

  defp assign(instance, key, identity, opts) do
    case Cache.config(instance) do
      {:ok, %{cache_enabled: true} = config} ->
        targeted_or(config, instance, key, opts, fn ->
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
        targeted_or(config, instance, key, opts, fn ->
          config |> read_variant(key) |> assign_from(key, identity, opts)
        end)
    end
  end

  # A rule pins the caller to a named arm, overriding the split: "force this
  # for them" would mean little otherwise.
  defp targeted_or(config, instance, key, opts, otherwise) do
    case targeted(config, instance, key, opts) do
      {:ok, targeted, _type} -> targeted
      :none -> otherwise.()
    end
  end

  defp targeted(%Config{cache_enabled: true}, instance, key, opts) do
    instance |> Cache.targets() |> Map.get(key) |> Targeting.resolve(key, fn -> context(opts) end)
  end

  # Uncached reads take the rules from the table, which is what a test that
  # adds one expects -- and nothing a test does reaches a cache another test
  # reads. The context comes first, so a caller without one never queries.
  defp targeted(%Config{} = config, _instance, key, opts) do
    case context(opts) do
      context when map_size(context) == 0 -> :none
      context -> config |> Targeting.load_for(key) |> Targeting.resolve(key, fn -> context end)
    end
  end

  defp context(opts) do
    case option(opts, :context, nil) do
      context when is_map(context) -> context
      context when is_list(context) -> to_context(context)
      _absent -> Context.get()
    end
  end

  defp to_context(list) do
    Map.new(list)
  rescue
    _not_a_keyword_list -> %{}
  end

  defp assign_from(%Variant{} = variant, key, identity, opts),
    do: Variant.assign(variant, key, identity, opts)

  defp assign_from(_other, _key, _identity, _opts), do: nil

  # Through the same decoding as the cache, or a secret would come back as its
  # ciphertext.
  defp read_row(config, key, default) do
    case read_entry(config, key) do
      %Entry{} = entry -> with nil <- Values.decode(entry, config), do: default
      nil -> default
    end
  end

  defp read_variant(config, key) do
    case read_entry(config, key) do
      %Entry{type: "variant"} = entry -> Values.decode(entry, config)
      _other -> nil
    end
  end

  # A test process without sandbox access, or a database that is down, reads
  # as a missing row: the caller gets its default.
  defp read_entry(%Config{}, key) when not is_binary(key), do: nil

  defp read_entry(%Config{} = config, key) do
    config.repo.get_by(Entry, key: key)
  rescue
    DBConnection.OwnershipError ->
      nil

    error ->
      Logger.warning("PhoenixFlags: read of #{inspect(key)} failed: #{inspect(error)}")
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
