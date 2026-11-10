defmodule WeaverWeb.DevicesController do
  @moduledoc """
  The Devices dialog's API, for the host's tenant: register, rename and
  remove the machines in `Weaver.Nodes`. The list itself, and who is online,
  arrive over the lobby channel. Registering a device, or asking to
  reinstall one, returns an install `code`; see
  `WeaverWeb.NodeInstallController`.
  """
  use WeaverWeb, :controller

  alias Weaver.Nodes

  def index(conn, _params), do: json(conn, %{nodes: Nodes.list(conn.assigns.tenant)})

  def create(conn, params) do
    case Nodes.create(conn.assigns.tenant, params["name"]) do
      {:ok, node, code} -> conn |> put_status(201) |> json(%{node: node, code: code})
      {:error, reason} -> refuse(conn, reason)
    end
  end

  def update(conn, %{"id" => id} = params) do
    case Nodes.rename(conn.assigns.tenant, id, params["name"]) do
      {:ok, node} -> json(conn, %{node: node})
      {:error, reason} -> refuse(conn, reason)
    end
  end

  def delete(conn, %{"id" => id}) do
    case Nodes.delete(conn.assigns.tenant, id) do
      :ok -> send_resp(conn, 204, "")
      {:error, reason} -> refuse(conn, reason)
    end
  end

  def install(conn, %{"id" => id}) do
    case Nodes.install_code(conn.assigns.tenant, id) do
      {:ok, code} -> json(conn, %{code: code})
      {:error, reason} -> refuse(conn, reason)
    end
  end

  defp refuse(conn, :not_found), do: conn |> put_status(404) |> json(%{error: "no such device"})

  defp refuse(conn, reason) when is_binary(reason),
    do: conn |> put_status(422) |> json(%{error: reason})

  
end
