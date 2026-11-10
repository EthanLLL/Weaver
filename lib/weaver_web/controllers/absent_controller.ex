defmodule WeaverWeb.AbsentController do
  @moduledoc "What the frontend asks for that Weaver does not have yet: devices."
  use WeaverWeb, :controller

  def devices(conn, _), do: json(conn, %{nodes: []})
end
