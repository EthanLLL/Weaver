defmodule WeaverWeb.Plugs.Tenant do
  @moduledoc """
  The tenant is the host, `<tenant>.<domain>`; any other host gets a 404.
  Except the platform's own, `weaver.<domain>`, where people sign up: the
  app's shell and `POST /api/signup`, and nothing of any tenant's.
  """
  import Plug.Conn

  @platform ["/", "/api/signup"]

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      WeaverWeb.Tenant.platform?(conn.host) ->
        if conn.request_path in @platform, do: conn, else: not_found(conn)

      true ->
        case WeaverWeb.Tenant.from_host(conn.host) do
          {:ok, tenant} -> assign(conn, :tenant, tenant)
          :error -> not_found(conn)
        end
    end
  end

  defp not_found(conn), do: conn |> send_resp(404, "no such tenant\n") |> halt()
end
