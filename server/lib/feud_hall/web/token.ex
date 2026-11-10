defmodule FeudHall.Web.Token do
  @moduledoc false

  def new_id, do: :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)

  def sign(kind, id) do
    payload = "#{kind}.#{id}"
    payload <> "." <> signature(payload)
  end

  def verify(kind, token) when is_binary(token) and byte_size(token) <= 220 do
    with [scope, id, supplied] <- String.split(token, ".", parts: 3),
         true <- scope == Atom.to_string(kind) and byte_size(id) in 1..70,
         true <- Plug.Crypto.secure_compare(supplied, signature("#{scope}.#{id}")) do
      {:ok, id}
    else
      _ -> {:error, :invalid_credential}
    end
  end

  def verify(_kind, _token), do: {:error, :invalid_credential}

  defp signature(payload) do
    key = Application.fetch_env!(:feud_hall, __MODULE__) |> Keyword.fetch!(:secret)
    :crypto.mac(:hmac, :sha256, key, payload) |> Base.url_encode64(padding: false)
  end
end
