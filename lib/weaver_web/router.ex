defmodule WeaverWeb.Router do
  @moduledoc """
  Loom's API, for the tenant the host names (`WeaverWeb.Plugs.Tenant` has
  put it in `conn.assigns.tenant` before this runs). Loom's apps are not here.
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
    # Only on the platform's host (`WeaverWeb.Plugs.Tenant`).
    post("/signup", SignupController, :create)
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

    get("/devices", DevicesController, :index)
    post("/devices", DevicesController, :create)
    patch("/devices/:id", DevicesController, :update)
    delete("/devices/:id", DevicesController, :delete)
    post("/devices/:id/install", DevicesController, :install)

    get("/push", PushController, :show)
    post("/push/subscriptions", PushController, :create)
    delete("/push/subscriptions", PushController, :delete)
  end

  scope "/canvas", WeaverWeb do
    get("/:id/:token", CanvasController, :show)
    get("/:id/:token/*path", CanvasController, :show)
  end

  scope "/canvas-files", WeaverWeb do
    get("/:id/:token/:name", CanvasController, :attachment)
  end

  # A device joining: the install script (its one-time code is the
  # credential) and the binary it downloads. See
  # `WeaverWeb.NodeInstallController`.
  scope "/node", WeaverWeb do
    get("/install/:code", NodeInstallController, :script)
    get("/download/:target", NodeInstallController, :download)
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
