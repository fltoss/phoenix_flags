defmodule PhoenixFlags.Audit do
  @moduledoc false

  # Writing and reading the audit log. Writing never fails a change: the value
  # is already saved by the time it is recorded.

  import Ecto.Query

  alias PhoenixFlags.AuditLog
  alias PhoenixFlags.Config

  require Logger

  def record(%Config{audit: true} = config, key, old_value, new_value, type, actor) do
    config.repo.insert(%AuditLog{
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

  def list(%Config{} = config), do: config.repo.all(newest_first(AuditLog))

  def list(%Config{} = config, key) do
    config.repo.all(newest_first(from(a in AuditLog, where: a.key == ^key)))
  end

  @doc "The config, raising unless it records an audit log."
  def enabled!(%Config{audit: true} = config), do: config

  def enabled!(%Config{name: name}) do
    raise PhoenixFlags.Error,
          "audit_log is not available because #{inspect(name)} is not configured with " <>
            "`audit: true`. Enable it in your `use PhoenixFlags` options and run the V2 " <>
            "migration (PhoenixFlags.Migration.up(version: 2)) to create the audit table."
  end

  defp newest_first(query), do: order_by(query, [a], desc: a.inserted_at, desc: a.id)

  defp redact("", _type), do: ""
  defp redact(nil, _type), do: nil
  defp redact(_value, "secret"), do: "[redacted]"
  defp redact(value, _type), do: value
end
