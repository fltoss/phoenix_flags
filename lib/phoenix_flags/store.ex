defmodule PhoenixFlags.Store do
  @moduledoc false

  # Reading and writing a flag's row. Both write paths -- through the Server
  # when cached, in the caller when not -- go through update/4, so encrypting,
  # validating and auditing happen the same way on each.

  alias PhoenixFlags.Audit
  alias PhoenixFlags.Config
  alias PhoenixFlags.Declarations
  alias PhoenixFlags.Entry
  alias PhoenixFlags.Values

  def all(%Config{} = config), do: config.repo.all(Entry)

  @doc "`{:ok, entry}`, or `{:error, :not_found}` -- including for a key that is not a string."
  def fetch(%Config{} = config, key) when is_binary(key) do
    case config.repo.get_by(Entry, key: key) do
      %Entry{} = entry -> {:ok, entry}
      nil -> {:error, :not_found}
    end
  end

  def fetch(_config, _key), do: {:error, :not_found}

  @doc """
  The changeset a new value goes through: encrypted when secret, then checked
  against the type and the declaration. Keeping them in one place is what
  stopped `:select` membership going unchecked on both paths at once.
  """
  def changeset(%Config{name: name} = config, %Entry{} = entry, attrs) do
    attrs = Values.encrypt_attrs(attrs, entry.type, config)

    Entry.changeset(entry, attrs,
      select_options: Declarations.select_options(name, entry.key),
      variants: Declarations.variant_names(name, entry.key)
    )
  end

  @doc "Saves a new value and records it in the audit log."
  def update(%Config{} = config, %Entry{} = entry, attrs, actor) do
    with {:ok, updated} <- config.repo.update(changeset(config, entry, attrs)) do
      Audit.record(config, entry.key, entry.value, updated.value, entry.type, actor)
      {:ok, updated}
    end
  end
end
