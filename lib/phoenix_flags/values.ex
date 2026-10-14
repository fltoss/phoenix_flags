defmodule PhoenixFlags.Values do
  @moduledoc false

  # Between a stored string and what a caller gets: casting it, decrypting a
  # secret, applying a variant's declared ttl and seed -- and, on the way in,
  # encrypting a secret so plaintext never reaches the table.

  alias PhoenixFlags.Config
  alias PhoenixFlags.Declarations
  alias PhoenixFlags.Entry

  require Logger

  @doc "The runtime value of a stored entry."
  def decode(%Entry{type: "secret", value: ""}, _config), do: nil

  def decode(%Entry{type: "secret", value: value, key: key}, %Config{encryptor: encryptor})
      when not is_nil(encryptor) do
    # Some crypto APIs (e.g. :crypto.crypto_one_time_aead/7) signal failure
    # by returning the atom :error instead of raising — never cache that as
    # if it were the plaintext.
    case encryptor.decrypt(value) do
      plaintext when is_binary(plaintext) ->
        plaintext

      other ->
        Logger.warning(
          "PhoenixFlags: failed to decrypt secret #{inspect(key)}: decrypt/1 returned " <>
            "#{describe_shape(other)}, not a binary"
        )

        nil
    end
  rescue
    error ->
      Logger.warning(
        "PhoenixFlags: failed to decrypt secret #{inspect(key)}: #{inspect(error.__struct__)} raised"
      )

      nil
  end

  # ttl and seed are declaration-level, so they are applied here rather than in
  # Entry.cast_value/2, which only sees the stored string.
  def decode(%Entry{type: "variant", value: value, key: key}, %Config{name: name}) do
    case Entry.cast_value(value, "variant") do
      %PhoenixFlags.Variant{} = variant ->
        case Declarations.variant(name, key) do
          %PhoenixFlags.Flag{ttl: ttl, seed: seed} -> %{variant | ttl: ttl, seed: seed}
          nil -> variant
        end

      nil ->
        nil
    end
  end

  def decode(%Entry{value: value, type: type}, _config), do: Entry.cast_value(value, type)

  @doc "Write attrs with a secret's value encrypted. An empty value clears and stays empty."
  def encrypt_attrs(attrs, "secret", %Config{encryptor: encryptor}) when not is_nil(encryptor) do
    case fetch_value(attrs) do
      {:ok, _key, ""} -> attrs
      {:ok, map_key, value} -> Map.put(attrs, map_key, encryptor.encrypt(value))
      :error -> attrs
    end
  end

  def encrypt_attrs(attrs, _type, _config), do: attrs

  @doc "A seed row with a secret's declared default encrypted."
  def encrypt_seed(%{type: "secret", value: value} = seed, %Config{encryptor: encryptor})
      when value not in [nil, ""] and not is_nil(encryptor) do
    %{seed | value: encryptor.encrypt(value)}
  end

  def encrypt_seed(seed, _config), do: seed

  defp fetch_value(%{"value" => value}), do: {:ok, "value", value}
  defp fetch_value(%{value: value}), do: {:ok, :value, value}
  defp fetch_value(_attrs), do: :error

  # Never the value itself: an encryptor wrapping an {:ok, plaintext} API would
  # otherwise log the secret on every cache load.
  defp describe_shape(atom) when is_atom(atom), do: inspect(atom)

  defp describe_shape(tuple)
       when is_tuple(tuple) and tuple_size(tuple) > 0 and is_atom(elem(tuple, 0)),
       do: "a #{tuple_size(tuple)}-tuple tagged #{inspect(elem(tuple, 0))}"

  defp describe_shape(_other), do: "a non-binary term"
end
