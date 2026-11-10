defmodule WeaverWeb.AuthController do
  use WeaverWeb, :controller

  # POST /api/login — the host's tenant's password, for a signed token. A wrong guess costs a second.
  def login(conn, %{"password" => password}) do
    t = conn.assigns.tenant

    if Weaver.Accounts.authenticate(t, password) == :ok do
      json(conn, %{token: WeaverWeb.Auth.mint_token(t)})
    else
      Process.sleep(1000)
      conn |> put_status(:unauthorized) |> json(%{error: "invalid_password"})
    end
  end

  def login(conn, _), do: conn |> put_status(:bad_request) |> json(%{error: "missing_password"})
end
