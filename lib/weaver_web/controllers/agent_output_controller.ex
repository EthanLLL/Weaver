defmodule WeaverWeb.AgentOutputController do
  @moduledoc "Downloads of what an agent produced (Loom's), read out of the tenant's VM."
  use WeaverWeb, :controller

  import WeaverWeb.At

  alias Weaver.Agent.{Download, Output}

  # GET /api/agents/:id/tree
  def tree(conn, %{"id" => id}) do
    case at(conn, Download, :tree, [id]) do
      {:ok, tree} -> json(conn, tree)
      _ -> conn |> put_status(:not_found) |> json(%{error: "unknown session"})
    end
  end

  # GET /api/agents/:id/zip/*path
  def zip(conn, %{"id" => id, "path" => parts}) do
    case at(conn, Download, :zip, [id, Path.join(parts)]) do
      {:ok, name, zip} ->
        send_download(conn, {:binary, zip}, filename: name)

      {:error, :too_large} ->
        conn |> put_status(:request_entity_too_large) |> json(%{error: "too big to zip"})

      _ ->
        conn |> put_status(:not_found) |> json(%{error: "no such output directory"})
    end
  end

  # DELETE /api/agents/:id/output/*path
  def delete(conn, %{"id" => id, "path" => parts}) do
    case at(conn, Output, :delete, [id, Path.join(parts)]) do
      :ok -> send_resp(conn, :no_content, "")
      _ -> conn |> put_status(:not_found) |> json(%{error: "no such output"})
    end
  end

  # PATCH /api/agents/:id/output/*path {new_name}
  def update(conn, %{"id" => id, "path" => parts, "new_name" => name}) do
    case at(conn, Output, :rename, [id, Path.join(parts), name]) do
      {:ok, path} -> json(conn, %{path: path})
      {:error, reason} -> rename_failed(conn, reason)
      _ -> conn |> put_status(:not_found) |> json(%{error: "no such output"})
    end
  end

  @doc false
  def rename_failed(conn, :exists),
    do: conn |> put_status(:conflict) |> json(%{error: "that name is taken"})

  def rename_failed(conn, :bad_name),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: "not a usable name"})

  def rename_failed(conn, :not_found),
    do: conn |> put_status(:not_found) |> json(%{error: "no such file"})

  def rename_failed(conn, reason),
    do: conn |> put_status(:unprocessable_entity) |> json(%{error: inspect(reason)})

  # GET /api/agents/:id/output/*path
  def show(conn, %{"id" => id, "path" => parts}) do
    case at(conn, Download, :output, [id, Path.join(["." | parts])]) do
      {:ok, %{path: path, data: data}} ->
        send_download(conn, {:binary, data}, filename: Path.basename(path))

      _ ->
        conn |> put_status(:not_found) |> json(%{error: "no such output"})
    end
  end
end
