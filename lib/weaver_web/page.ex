defmodule WeaverWeb.Page do
  @moduledoc """
  The page, a terminal in the tenant's VM, and the login it needs. Unknown
  hosts get a 404 before anything else.

    * `GET /` the page
    * `POST /login` `{"password"}` → `{"token"}`, or 401
    * `GET /me` with `Authorization: Bearer <token>` → 204, or 401
  """
  use Plug.Router

  @page File.read!(Path.join(__DIR__, "page.html"))
  @external_resource Path.join(__DIR__, "page.html")

  plug(:tenant)
  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:dispatch)

  get "/" do
    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, String.replace(@page, "{{tenant}}", conn.assigns.tenant))
  end

  post "/login" do
    if WeaverWeb.Auth.valid_password?(conn.body_params["password"]) do
      json(conn, 200, %{token: WeaverWeb.Auth.mint_token()})
    else
      # A wrong guess costs a second.
      Process.sleep(1000)
      json(conn, 401, %{error: "invalid_password"})
    end
  end

  get "/me" do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         :ok <- WeaverWeb.Auth.verify_token(token) do
      send_resp(conn, 204, "")
    else
      _ -> json(conn, 401, %{error: "unauthorized"})
    end
  end

  match _ do
    send_resp(conn, 404, "not found\n")
  end

  defp tenant(conn, _) do
    case WeaverWeb.Tenant.from_host(conn.host) do
      {:ok, tenant} -> assign(conn, :tenant, tenant)
      :error -> conn |> send_resp(404, "no such tenant\n") |> halt()
    end
  end

  defp json(conn, status, body) do
    conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body))
  end
end
