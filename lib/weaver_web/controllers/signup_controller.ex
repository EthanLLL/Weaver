defmodule WeaverWeb.SignupController do
  use WeaverWeb, :controller

  # POST /api/signup on the platform's host — {name, password, invite}. The
  # token it answers with is for the new tenant's own host, where the app
  # takes it from the URL's fragment (`frontend/src/api.ts`). A refused code
  # costs a second, as a wrong password does.
  def create(conn, %{"name" => name, "password" => password, "invite" => invite})
      when is_binary(name) and is_binary(password) and is_binary(invite) do
    case Weaver.Accounts.signup(name, password, invite) do
      {:ok, t} ->
        json(conn, %{
          tenant: t,
          url: "https://#{t}.#{Application.fetch_env!(:weaver, :domain)}/",
          token: WeaverWeb.Auth.mint_token(t)
        })

      {:error, message} ->
        Process.sleep(1000)
        conn |> put_status(:unprocessable_entity) |> json(%{error: message})
    end
  end

  def create(conn, _),
    do:
      conn |> put_status(:bad_request) |> json(%{error: "name, password and invite are required"})
end
