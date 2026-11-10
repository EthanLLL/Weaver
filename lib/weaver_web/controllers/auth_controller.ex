defmodule WeaverWeb.AuthController do
  use WeaverWeb, :controller

  # POST /api/login — the one password, for a signed token. A wrong guess costs a second.
  def login(conn, %{"password" => password}) do
    if WeaverWeb.Auth.valid_password?(password) do
      json(conn, %{token: WeaverWeb.Auth.mint_token()})
    else
      Process.sleep(1000)
      conn |> put_status(:unauthorized) |> json(%{error: "invalid_password"})
    end
  end

  def login(conn, _), do: conn |> put_status(:bad_request) |> json(%{error: "missing_password"})
end
