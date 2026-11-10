defmodule WeaverWeb.Auth do
  @moduledoc """
  Each tenant's own password (`Weaver.Accounts`) buys a signed token for
  that tenant, kept by the browser on the tenant's host. A token names its
  tenant and is good for no other: the tenant is still the host, and the
  token must agree with it. Tokens are signed with the endpoint's
  `secret_key_base`, which every node shares, so any node accepts a token
  any other minted.
  """

  @salt "weaver auth token"
  @max_age 60 * 60 * 24 * 30

  def mint_token(tenant), do: Phoenix.Token.sign(WeaverWeb.Endpoint, @salt, %{t: tenant})

  @doc "`:ok` if `token` is tenant `t`'s and current."
  def verify_token(token, t) when is_binary(token) do
    case Phoenix.Token.verify(WeaverWeb.Endpoint, @salt, token, max_age: @max_age) do
      {:ok, %{t: ^t}} -> :ok
      {:ok, _} -> {:error, :other_tenant}
      {:error, reason} -> {:error, reason}
    end
  end

  def verify_token(_, _), do: {:error, :missing}
end
