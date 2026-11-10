defmodule WeaverWeb.TerminalChannel do
  @moduledoc """
  One client of one terminal (Loom's), `terminal:<id>`, for the socket's
  tenant. The shell runs in the VM; the terminal's process on the tenant's
  node sends this channel `{:pty_output, binary}` wherever it is.

  Client → server: binary "input", "resize" `%{cols, rows}`.
  Server → client: binary "output".
  """
  use Phoenix.Channel

  import WeaverWeb.At

  alias Weaver.Terminal

  @impl true
  def join("terminal:" <> id, params, socket) do
    if at(socket, Terminal, :exists?, [id]) do
      size =
        case params do
          %{"cols" => cols, "rows" => rows} when is_integer(cols) and is_integer(rows) ->
            {cols, rows}

          _ ->
            nil
        end

      :ok = at(socket, Terminal, :subscribe, [id, self(), size])
      Weaver.Tenant.hold(socket.assigns.tenant)
      {:ok, assign(socket, :terminal_id, id)}
    else
      {:error, %{reason: "unknown_session"}}
    end
  end

  @impl true
  def handle_in("input", {:binary, data}, socket) do
    at(socket, Terminal, :send_input, [socket.assigns.terminal_id, self(), data])
    {:noreply, socket}
  end

  def handle_in("resize", %{"cols" => cols, "rows" => rows}, socket) do
    at(socket, Terminal, :resize, [socket.assigns.terminal_id, self(), cols, rows])
    {:noreply, socket}
  end

  @impl true
  def handle_info({:pty_output, data}, socket) do
    push(socket, "output", {:binary, data})
    {:noreply, socket}
  end
end
