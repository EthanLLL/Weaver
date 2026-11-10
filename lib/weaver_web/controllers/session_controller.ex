defmodule WeaverWeb.SessionController do
  @moduledoc "The tenant's terminals (Loom's `/api/sessions`): shells in the VM."
  use WeaverWeb, :controller

  import WeaverWeb.At

  alias Weaver.Terminal

  def index(conn, _params) do
    json(conn, %{sessions: Enum.map(at(conn, Terminal, :list_sessions, []), &view/1)})
  end

  def create(conn, params) do
    id = "s_" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

    opts =
      [title: params["title"], cols: int(params["cols"]), rows: int(params["rows"])]
      |> Enum.reject(fn {_, v} -> is_nil(v) end)

    case at(conn, Terminal, :start_session, [id, opts]) do
      {:ok, _pid} ->
        conn |> put_status(:created) |> json(view(at(conn, Terminal, :info, [id])))

      {:error, reason} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})
    end
  end

  def delete(conn, %{"id" => id}) do
    case at(conn, Terminal, :stop_session, [id]) do
      :ok -> send_resp(conn, :no_content, "")
      {:error, :not_found} -> send_resp(conn, :not_found, "")
    end
  end

  defp int(n) when is_integer(n), do: n
  defp int(n) when is_binary(n), do: with({v, _} <- Integer.parse(n), do: v, else: (_ -> nil))
  defp int(_), do: nil

  defp view(info), do: Map.take(info, [:id, :title, :created_at, :cols, :rows])
end
