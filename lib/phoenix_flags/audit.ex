defmodule PhoenixFlags.Audit do
  @moduledoc false

  # Writing and reading the audit log. Writing never fails a change: the value
  # is already saved by the time it is recorded.

  import Ecto.Query

  alias PhoenixFlags.AuditLog
  alias PhoenixFlags.Config

  require Logger

  @doc "Records a change. A save that left the value as it was records nothing."
  def record(_config, _key, same, same, _type, _actor), do: :ok

  def record(%Config{audit: true} = config, key, old_value, new_value, type, actor) do
    config.repo.insert(%AuditLog{
      id: time_ordered_id(),
      key: key,
      old_value: redact(old_value, type),
      new_value: redact(new_value, type),
      actor: actor || "unknown"
    })
  rescue
    error ->
      Logger.error("PhoenixFlags: failed to insert audit log: #{inspect(error.__struct__)}")
  end

  def record(_config, _key, _old_value, _new_value, _type, _actor), do: :ok

  @doc "Newest first. `key: nil` is every flag; `:limit` caps the rows."
  def list(%Config{} = config, key, opts) do
    AuditLog
    |> for_key(key)
    |> order_by([a], desc: a.inserted_at, desc: a.id)
    |> limit_to(Keyword.get(opts, :limit))
    |> config.repo.all()
  end

  @doc "The config, raising unless it records an audit log."
  def enabled!(%Config{audit: true} = config), do: config

  def enabled!(%Config{name: name}) do
    raise PhoenixFlags.Error,
          "audit_log is not available because #{inspect(name)} is not configured with " <>
            "`audit: true`. Enable it in your `use PhoenixFlags` options and run the V2 " <>
            "migration (PhoenixFlags.Migration.up(version: 2)) to create the audit table."
  end

  defp for_key(query, nil), do: query
  defp for_key(query, key), do: where(query, [a], a.key == ^key)

  defp limit_to(query, limit) when is_integer(limit) and limit > 0, do: limit(query, ^limit)
  defp limit_to(query, _none), do: query

  # inserted_at is to the second, so within one second rows used to come back
  # in the order of random v4 ids. A UUIDv7 leads with the time, so the id
  # breaks the tie in the order the changes were made: the millisecond, then
  # the fraction of it in the next 12 bits (RFC 9562, section 6.2, method 3).
  defp time_ordered_id do
    microseconds = System.system_time(:microsecond)
    milliseconds = div(microseconds, 1000)
    fraction = div(rem(microseconds, 1000) * 4096, 1000)
    <<random::62, _unused::2>> = :crypto.strong_rand_bytes(8)

    {:ok, id} = Ecto.UUID.load(<<milliseconds::48, 7::4, fraction::12, 2::2, random::62>>)
    id
  end

  defp redact("", _type), do: ""
  defp redact(nil, _type), do: nil
  defp redact(_value, "secret"), do: "[redacted]"
  defp redact(value, _type), do: value
end
