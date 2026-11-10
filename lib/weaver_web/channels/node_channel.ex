defmodule WeaverWeb.NodeChannel do
  @moduledoc """
  One connected device: Loom's `LoomWeb.NodeChannel`, for a tenant. Relays
  requests from `Weaver.Calls.Node` down to the device and its answers back
  up, matched by an `id` the requester picks. The requester may be on another
  node (the VM's); messages and monitors cross nodes as they are.

  While joined, this process is in the `:pg` group
  `Weaver.Nodes.group(t, id)`: that is the device being online.

  Requester → channel (Erlang messages):
    - `{:node_send, pid, id, event, payload}`: push `event` to the device
      with `id` added. The first send for an `id` registers `pid` as the one
      its answers go to, and monitors it: if it goes away, the device is told
      to `cancel`.
    - `{:node_cancel, id}`: the same, for a requester that is still alive.

  Device → channel → requester, as `{:node_reply, id, event, payload}`:
  "out", "exit", "chunk", "done", "written", "error"; see Loom. "exit",
  "done", "written" and "error" end a request.
  """
  use Phoenix.Channel

  require Logger

  alias Weaver.Nodes

  @final ~w(exit done written error)

  @impl true
  def join("node", info, socket) do
    %{tenant: t, node_id: id} = socket.assigns

    case Nodes.connected(t, id, self(), info) do
      {:ok, device} ->
        :ok = :pg.join(Weaver.PG, Nodes.group(t, id), self())
        Nodes.announce(device)
        {:ok, %{name: device.name}, assign(socket, :requests, %{})}

      {:error, _} ->
        {:error, %{reason: "unknown device"}}
    end
  end

  @impl true
  def handle_in(event, %{"id" => id} = payload, socket)
      when event in ~w(out exit chunk done written error) do
    case socket.assigns.requests do
      %{^id => {pid, ref}} ->
        send(pid, {:node_reply, id, event, Map.delete(payload, "id")})

        if event in @final do
          Process.demonitor(ref, [:flush])
          {:noreply, update(socket, &Map.delete(&1, id))}
        else
          {:noreply, socket}
        end

      # Late output for a request already cancelled.
      _ ->
        {:noreply, socket}
    end
  end

  def handle_in(event, _payload, socket) do
    Logger.warning("NodeChannel: unexpected #{inspect(event)} from the device")
    {:noreply, socket}
  end

  @impl true
  def handle_info({:node_send, pid, id, event, payload}, socket) do
    socket =
      if Map.has_key?(socket.assigns.requests, id),
        do: socket,
        else: update(socket, &Map.put(&1, id, {pid, Process.monitor(pid)}))

    push(socket, event, Map.put(payload, "id", id))
    {:noreply, socket}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, socket) do
    case Enum.find(socket.assigns.requests, fn {_id, {_pid, r}} -> r == ref end) do
      {id, _} ->
        push(socket, "cancel", %{"id" => id})
        {:noreply, update(socket, &Map.delete(&1, id))}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_info({:node_cancel, id}, socket) do
    case socket.assigns.requests do
      %{^id => {_pid, ref}} ->
        Process.demonitor(ref, [:flush])
        push(socket, "cancel", %{"id" => id})
        {:noreply, update(socket, &Map.delete(&1, id))}

      _ ->
        {:noreply, socket}
    end
  end

  # A newer connection from the same device, or its token was revoked.
  def handle_info(:node_replaced, socket), do: {:stop, {:shutdown, :replaced}, socket}

  # Out of the group first, so the sidebar hears it offline.
  @impl true
  def terminate(_reason, %{assigns: %{tenant: t, node_id: id, requests: _}}) do
    :pg.leave(Weaver.PG, Nodes.group(t, id), self())
    Nodes.disconnected(t, id)
  end

  def terminate(_reason, _socket), do: :ok

  defp update(socket, fun), do: assign(socket, :requests, fun.(socket.assigns.requests))
end
