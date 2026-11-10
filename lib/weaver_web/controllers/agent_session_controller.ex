defmodule WeaverWeb.AgentSessionController do
  @moduledoc "Loom's session list API, for the host's tenant."
  use WeaverWeb, :controller

  import WeaverWeb.At

  alias Weaver.Agent

  # GET /api/agents
  def index(conn, _params) do
    json(conn, %{sessions: Enum.map(at(conn, Agent, :list_sessions, []), &view/1)})
  end

  # POST /api/agents — `backend` is required: `claude_code` or `codex`.
  def create(conn, params) do
    case Agent.Backend.parse(params["backend"]) do
      {:ok, backend} ->
        id = Agent.new_id()
        opts = [backend: backend] ++ if(params["title"], do: [title: params["title"]], else: [])

        with {:ok, _pid} <- at(conn, Agent, :start_session, [id, opts]),
             info when is_map(info) <- at(conn, Agent, :info, [id]) do
          conn |> put_status(:created) |> json(view(info))
        else
          other -> conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(other)})
        end

      :error ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "`backend` must be \"claude_code\" or \"codex\"",
          given: params["backend"]
        })
    end
  end

  # PATCH /api/agents/:id with `directory` or `title`
  def update(conn, %{"id" => id, "directory" => directory}),
    do: updated(conn, id, at(conn, Agent, :move, [id, directory]))

  def update(conn, %{"id" => id, "title" => title}),
    do: updated(conn, id, at(conn, Agent, :rename, [id, title]))

  defp updated(conn, id, :ok), do: json(conn, view(at(conn, Agent, :info, [id])))

  defp updated(conn, _id, {:error, reason}),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})

  # DELETE /api/agents/:id — stop it and move its history to the VM's trash.
  def delete(conn, %{"id" => id}) do
    at(conn, Agent, :delete_session, [id])
    send_resp(conn, :no_content, "")
  end

  # POST /api/directories/move
  def move_directory(conn, %{"from" => from, "to" => to}) do
    case at(conn, Agent, :move_directory, [from, to]) do
      :ok -> send_resp(conn, :no_content, "")
      {:error, reason} -> conn |> put_status(:unprocessable_entity) |> json(%{error: reason})
    end
  end

  defp view(info) do
    Map.take(info, [
      :id,
      :title,
      :directory,
      :backend,
      :backend_label,
      :created_at,
      :last_active_at,
      :status,
      :queued,
      :queue,
      :usage,
      :context_tokens,
      :context_window,
      :turns,
      :seq
    ])
  end
end
