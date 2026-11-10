defmodule WeaverWeb.TerminalChannel do
  @moduledoc """
  A terminal in the tenant's VM: a login shell as the user `tenant`, on a pty,
  for as long as the channel lives. The shell runs on whichever node has the
  VM; this channel may be on another.

  In: "i" `%{data}` keystrokes, "z" `%{rows, cols}`. Out: "o" binary output,
  "exit" `%{status}`.
  """
  use Phoenix.Channel

  @impl true
  def join("terminal", %{"rows" => rows, "cols" => cols}, socket)
      when is_integer(rows) and is_integer(cols) do
    tenant = socket.assigns.tenant

    with {:ok, node} <- Weaver.where(tenant),
         {:ok, exec} <-
           :erpc.call(node, Weaver.Exec, :start, [
             tenant,
             ["bash", "-l"],
             self(),
             [user: "tenant", pty: {clamp(rows), clamp(cols)}]
           ]) do
      {:ok, %{tenant: tenant, node: node}, assign(socket, :exec, exec)}
    else
      {:error, reason} -> {:error, %{reason: inspect(reason)}}
    end
  end

  def join("terminal", _, _), do: {:error, %{reason: "rows and cols"}}

  @impl true
  def handle_in("i", %{"data" => data}, socket) when is_binary(data) do
    Weaver.Exec.write(socket.assigns.exec, data)
    {:noreply, socket}
  end

  def handle_in("z", %{"rows" => rows, "cols" => cols}, socket)
      when is_integer(rows) and is_integer(cols) do
    Weaver.Exec.resize(socket.assigns.exec, clamp(rows), clamp(cols))
    {:noreply, socket}
  end

  @impl true
  def handle_info({exec, {:data, _, data}}, %{assigns: %{exec: exec}} = socket) do
    push(socket, "o", {:binary, data})
    {:noreply, socket}
  end

  def handle_info({exec, {:exit_status, status}}, %{assigns: %{exec: exec}} = socket) do
    push(socket, "exit", %{status: status})
    {:stop, :normal, socket}
  end

  def handle_info({exec, {:error, reason}}, %{assigns: %{exec: exec}} = socket) do
    push(socket, "exit", %{status: inspect(reason)})
    {:stop, :normal, socket}
  end

  defp clamp(n), do: n |> max(2) |> min(500)
end
