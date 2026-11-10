defmodule WeaverWeb.DevicesController do
  @moduledoc """
  The Devices dialog's API, for the host's tenant: register, rename and
  remove the machines in `Weaver.Nodes`. The list itself, and who is online,
  arrive over the lobby channel. Registering a device, or asking to
  reinstall one, returns an install `code`; see
  `WeaverWeb.NodeInstallController`.
  """
  use WeaverWeb, :controller

  import WeaverWeb.At, only: [at: 4]

  alias Weaver.Nodes

  def index(conn, _params), do: json(conn, %{nodes: at(conn, Nodes, :list, [])})

  def create(conn, params) do
    case at(conn, Nodes, :create, [params["name"]]) do
      {:ok, node, code} -> conn |> put_status(201) |> json(%{node: node, code: code})
      {:error, reason} -> refuse(conn, reason)
    end
  end

  def update(conn, %{"id" => id} = params) do
    case at(conn, Nodes, :rename, [id, params["name"]]) do
      {:ok, node} -> json(conn, %{node: node})
      {:error, reason} -> refuse(conn, reason)
    end
  end

  def delete(conn, %{"id" => id}) do
    case at(conn, Nodes, :delete, [id]) do
      :ok -> send_resp(conn, 204, "")
      {:error, reason} -> refuse(conn, reason)
    end
  end

  def install(conn, %{"id" => id}) do
    case at(conn, Nodes, :install_code, [id]) do
      {:ok, code} -> json(conn, %{code: code})
      {:error, reason} -> refuse(conn, reason)
    end
  end

  defp refuse(conn, :not_found), do: conn |> put_status(404) |> json(%{error: "no such device"})

  defp refuse(conn, reason) when is_binary(reason),
    do: conn |> put_status(422) |> json(%{error: reason})

  defp refuse(conn, reason), do: conn |> put_status(503) |> json(%{error: inspect(reason)})
end
