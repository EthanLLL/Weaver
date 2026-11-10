defmodule WeaverWeb.Router do
  @moduledoc """
  Loom's API, for the tenant the host names (`WeaverWeb.Plugs.Tenant` has
  put it in `conn.assigns.tenant` before this runs). Loom's devices and push
  notifications are not here (yet), nor its apps; the frontend gets empty
  answers for those.
  """
  use WeaverWeb, :router

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :authed_api do
    plug(:accepts, ["json"])
    plug(WeaverWeb.Plugs.RequireAuth)
  end

  scope "/api", WeaverWeb do
    pipe_through(:api)
    post("/login", AuthController, :login)
  end

  scope "/api", WeaverWeb do
    pipe_through(:authed_api)

    get("/sessions", SessionController, :index)
    post("/sessions", SessionController, :create)
    delete("/sessions/:id", SessionController, :delete)

    get("/agents", AgentSessionController, :index)
    post("/agents", AgentSessionController, :create)
    patch("/agents/:id", AgentSessionController, :update)
    delete("/agents/:id", AgentSessionController, :delete)
    post("/directories/move", AgentSessionController, :move_directory)

    post("/agents/:id/files", AgentFileController, :create)
    get("/agents/:id/files/:name", AgentFileController, :show)
    patch("/agents/:id/files/:name", AgentFileController, :update)
    delete("/agents/:id/files/:name", AgentFileController, :delete)
    get("/agents/:id/output/*path", AgentOutputController, :show)
    patch("/agents/:id/output/*path", AgentOutputController, :update)
    delete("/agents/:id/output/*path", AgentOutputController, :delete)
    get("/agents/:id/zip/*path", AgentOutputController, :zip)
    get("/agents/:id/tree", AgentOutputController, :tree)
    post("/agents/:id/canvas", CanvasController, :token)

    get("/layout", LayoutController, :show)
    put("/layout", LayoutController, :update)

    get("/devices", AbsentController, :devices)
    get("/push", AbsentController, :not_here)
  end

  scope "/canvas", WeaverWeb do
    get("/:id/:token", CanvasController, :show)
    get("/:id/:token/*path", CanvasController, :show)
  end

  scope "/canvas-files", WeaverWeb do
    get("/:id/:token/:name", CanvasController, :attachment)
  end

  # The user taking over the tenant's browser; see `WeaverWeb.VncSocket`.
  # Checks the token itself.
  scope "/browser", WeaverWeb do
    get("/vnc", BrowserController, :vnc)
  end

  scope "/", WeaverWeb do
    get("/", SpaController, :index)
  end
end
