defmodule WeaverWeb.AbsentController do
  @moduledoc "What the frontend asks for that Weaver does not have yet: devices, push."
  use WeaverWeb, :controller

  def devices(conn, _), do: json(conn, %{nodes: []})
  def not_here(conn, _), do: conn |> put_status(:not_found) |> json(%{error: "not in Weaver"})
end
