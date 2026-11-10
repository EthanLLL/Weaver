defmodule WeaverWeb.Auth do
  @moduledoc """
  One password for everyone, as in Loom: `WEAVER_PASSWORD`. It buys a signed
  token, kept by the browser per tenant host; the tenant itself is still only
  the host. Tokens are signed with the endpoint's `secret_key_base`, which
  every node shares, so any node accepts a token any other minted.
  """

  @salt "weaver auth token"
  @max_age 60 * 60 * 24 * 30

  def valid_password?(password) when is_binary(password) do
    configured = Application.fetch_env!(:weaver, :password)
    configured != "" and Plug.Crypto.secure_compare(password, configured)
  end

  def valid_password?(_), do: false

  def mint_token, do: Phoenix.Token.sign(WeaverWeb.Endpoint, @salt, %{ok: true})

  def verify_token(token) when is_binary(token) do
    case Phoenix.Token.verify(WeaverWeb.Endpoint, @salt, token, max_age: @max_age) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def verify_token(_), do: {:error, :missing}
end
