defmodule WeaverWeb.Plugs.Tenant do
  @moduledoc "The tenant is the host, `<tenant>.<domain>`; any other host gets a 404."
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    case WeaverWeb.Tenant.from_host(conn.host) do
      {:ok, tenant} -> assign(conn, :tenant, tenant)
      :error -> conn |> send_resp(404, "no such tenant\n") |> halt()
    end
  end
end
