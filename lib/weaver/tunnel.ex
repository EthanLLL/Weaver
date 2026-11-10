defmodule Weaver.Tunnel do
  @moduledoc """
  A TCP connection to a port on a tenant VM's loopback, carried over its
  vsock by `weaver-guest` (`guest/tunnel.go`): how the host reaches a service
  in the VM, such as the browser's VNC, without the VM's network, which
  carries only its traffic to the internet (`host/vm.sh`).

  Held, like `Weaver.Exec`, by a process on the VM's node for an owner that
  may be anywhere, and gone when the owner is. The owner gets

    * `{pid, {:data, binary}}`, one at a time: the next comes after `ack/1`,
      so a slow reader holds the VM's side back instead of filling a mailbox
    * `{pid, :closed}`, last, when the other end closes
    * `{pid, {:error, reason}}`, last; `"econnrefused"` when nothing listens
  """
  use GenServer, restart: :temporary

  @doc "Connect to `port` on `vm`'s loopback, from any node, for `owner`."
  def open(vm, port, owner \\ self()) do
    with {:ok, node} <- Weaver.Tenant.vm_node(vm) do
      :erpc.call(node, DynamicSupervisor, :start_child, [
        Weaver.Execs,
        {__MODULE__, {vm, port, owner}}
      ])
    end
  end

  def write(pid, data), do: GenServer.cast(pid, {:frame, ?i, data})
  def ack(pid), do: GenServer.cast(pid, :ack)

  def close(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init({vm, port, owner}) do
    Process.monitor(owner)

    with {:ok, sock} <- Weaver.Guest.connect(vm),
         :ok <- :gen_tcp.send(sock, [?t, JSON.encode!(%{port: port})]),
         :ok <- :inet.setopts(sock, active: :once) do
      {:ok, %{sock: sock, owner: owner}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_cast({:frame, type, data}, state) do
    :gen_tcp.send(state.sock, [type, data])
    {:noreply, state}
  end

  def handle_cast(:ack, state) do
    :inet.setopts(state.sock, active: :once)
    {:noreply, state}
  end

  @impl true
  def handle_info({:tcp, _, <<?o, data::binary>>}, state) do
    send(state.owner, {self(), {:data, data}})
    {:noreply, state}
  end

  def handle_info({:tcp, _, <<?q, _::32>>}, state), do: last(state, :closed)
  def handle_info({:tcp, _, <<?f, why::binary>>}, state), do: last(state, {:error, why})
  def handle_info({:tcp_closed, _}, state), do: last(state, :closed)
  def handle_info({:DOWN, _, :process, _, _}, state), do: {:stop, :normal, state}

  defp last(state, msg) do
    send(state.owner, {self(), msg})
    {:stop, :normal, state}
  end
end
