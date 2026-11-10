defmodule WeaverWeb.Page do
  @moduledoc "The one page: a terminal in the tenant's VM. Unknown hosts get a 404."
  @behaviour Plug
  import Plug.Conn

  @page File.read!(Path.join(__DIR__, "page.html"))
  @external_resource Path.join(__DIR__, "page.html")

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{request_path: "/"} = conn, _) do
    case WeaverWeb.Tenant.from_host(conn.host) do
      {:ok, tenant} ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(200, String.replace(@page, "{{tenant}}", tenant))

      :error ->
        send_resp(conn, 404, "no such tenant\n")
    end
  end

  def call(conn, _), do: send_resp(conn, 404, "not found\n")
end
