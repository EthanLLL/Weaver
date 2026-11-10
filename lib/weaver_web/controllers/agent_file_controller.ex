defmodule WeaverWeb.AgentFileController do
  @moduledoc """
  Uploads for one session's attachments (Loom's). An upload is spooled to a
  temp file on whichever node took the request; its contents go to the
  tenant's VM from there.
  """
  use WeaverWeb, :controller

  import WeaverWeb.At

  alias Weaver.Agent
  alias Weaver.Agent.{Download, Files}

  # POST /api/agents/:id/files — multipart, one or many `files[]`.
  def create(conn, %{"id" => id} = params) do
    cond do
      at(conn, Agent, :exists?, [id]) != true ->
        conn |> put_status(:not_found) |> json(%{error: "unknown session"})

      uploads(params) == [] ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "no files in the request"})

      true ->
        store_all(conn, id, uploads(params))
    end
  end

  # GET /api/agents/:id/files/:name
  def show(conn, %{"id" => id, "name" => name}) do
    case at(conn, Download, :attachment, [id, name]) do
      {:ok, %{name: name, data: data}} ->
        conn
        |> put_resp_header("cache-control", "private, max-age=86400")
        |> send_download({:binary, data}, filename: name)

      _ ->
        conn |> put_status(:not_found) |> json(%{error: "no such attachment"})
    end
  end

  # DELETE /api/agents/:id/files/:name
  def delete(conn, %{"id" => id, "name" => name}) do
    case at(conn, Files, :delete, [id, name]) do
      :ok -> send_resp(conn, :no_content, "")
      _ -> conn |> put_status(:not_found) |> json(%{error: "no such attachment"})
    end
  end

  # PATCH /api/agents/:id/files/:name {new_name}
  def update(conn, %{"id" => id, "name" => name, "new_name" => new_name}) do
    case at(conn, Files, :rename, [id, name, new_name]) do
      {:ok, stored} -> json(conn, %{path: stored})
      {:error, reason} -> WeaverWeb.AgentOutputController.rename_failed(conn, reason)
      _ -> conn |> put_status(:not_found) |> json(%{error: "no such attachment"})
    end
  end

  defp store_all(conn, id, uploads) do
    results =
      Enum.map(uploads, fn upload ->
        at(conn, Files, :store, [id, %{filename: upload.filename, data: File.read!(upload.path)}])
      end)

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil ->
        json(conn, %{files: Enum.map(results, fn {:ok, file} -> file end)})

      {:error, reason} ->
        # All or nothing, as in Loom.
        for {:ok, file} <- results, do: at(conn, Files, :delete, [id, file.name])
        conn |> put_status(status_for(reason)) |> json(%{error: message_for(reason)})
    end
  end

  defp status_for(:too_large), do: :request_entity_too_large
  defp status_for(_other), do: :unprocessable_entity

  defp message_for(:too_large), do: "a file is larger than 25 MB"
  defp message_for(:empty), do: "a file is empty"
  defp message_for(reason), do: "could not store the file: #{inspect(reason)}"

  defp uploads(params) do
    [Map.get(params, "files"), Map.get(params, "file")]
    |> Enum.flat_map(fn
      %Plug.Upload{} = upload -> [upload]
      list when is_list(list) -> Enum.filter(list, &match?(%Plug.Upload{}, &1))
      _ -> []
    end)
  end
end
