defmodule Weaver.Calls do
  @moduledoc """
  Programs in a VM calling Weaver (`weaver <method> [json]` in the guest).

  A guest that dials the host's vsock port 1025 reaches the Unix socket
  `vsock.sock_1025` beside the VM's own; one is listened on for each VM on
  this host. Which socket a call came in on is which tenant made it, so a
  call carries no credentials, and a method sees only its own tenant.

  Methods are the `call/3` clauses below and nothing else.
  """
  use GenServer

  require Logger

  @port 1025

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Listen for `vm`'s calls, if not already."
  def ensure(vm), do: GenServer.call(__MODULE__, {:ensure, vm})

  # The methods. `tenant` is the VM the call came from.
  defp call(tenant, "whoami", _args), do: {:ok, %{tenant: tenant, host: node()}}
  defp call(_tenant, "echo", args), do: {:ok, args}
  defp call(_tenant, method, _args), do: {:error, "no such method: #{method}"}

  @impl true
  def init(nil) do
    {:ok, %{}, {:continue, :listen}}
  end

  @impl true
  def handle_continue(:listen, state) do
    {:noreply, Enum.reduce(Weaver.Host.vms(), state, &listen(&2, &1.name))}
  end

  @impl true
  def handle_call({:ensure, vm}, _from, state), do: {:reply, :ok, listen(state, vm)}

  defp listen(state, vm) when is_map_key(state, vm), do: state

  defp listen(state, vm) do
    path = Path.join([Weaver.Host.dir(), vm, "vsock.sock_#{@port}"])
    File.rm(path)

    case :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, packet: 4, active: false]) do
      {:ok, lsock} ->
        Map.put(state, vm, spawn_link(fn -> accept(lsock, vm) end))

      {:error, reason} ->
        Logger.error("Weaver.Calls cannot listen for #{vm}: #{inspect(reason)}")
        state
    end
  end

  # The listener lives as long as the VM is on this host, so it is also what
  # says where the VM is (`Weaver.Tenant.vm_node/1`).
  defp accept(lsock, vm) do
    :pg.join(Weaver.PG, {:vm, vm}, self())
    accept_loop(lsock, vm)
  end

  defp accept_loop(lsock, vm) do
    {:ok, sock} = :gen_tcp.accept(lsock)
    pid = spawn(fn -> serve(sock, vm) end)
    :gen_tcp.controlling_process(sock, pid)
    send(pid, :go)
    accept_loop(lsock, vm)
  end

  defp serve(sock, vm) do
    receive do: (:go -> :ok)

    with {:ok, <<?c, body::binary>>} <- :gen_tcp.recv(sock, 0, 10_000),
         {:ok, %{"method" => method} = req} <- JSON.decode(body) do
      case call(vm, method, req["args"] || %{}) do
        {:ok, reply} ->
          :gen_tcp.send(sock, [?o, JSON.encode!(reply)]) && :gen_tcp.send(sock, <<?q, 0::32>>)

        {:error, why} ->
          :gen_tcp.send(sock, [?f, why])
      end
    else
      _ -> :gen_tcp.send(sock, [?f, "bad call"])
    end

    :gen_tcp.close(sock)
  end
end
