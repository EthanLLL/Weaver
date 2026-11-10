defmodule Weaver.Exec do
  @moduledoc """
  A process in a tenant VM, held by an Erlang process that stands in for a
  port: it talks to `weaver-guest` over the VM's vsock and sends its owner

    * `{pid, {:data, :stdout | :stderr, binary}}`
    * `{pid, {:exit_status, integer}}`, last
    * `{pid, {:error, reason}}`, last, if it could not run or the VM went away

  The owner may be on another node; that is the point. If the owner dies the
  connection closes, and the guest kills the process.

  Wire format: see `guest/main.go`.
  """
  use GenServer, restart: :temporary

  @port 1024

  @doc "Run `argv` in `vm` on this host, for `owner`."
  def start(vm, argv, owner \\ self(), opts \\ []) do
    DynamicSupervisor.start_child(Weaver.Execs, {__MODULE__, {vm, argv, owner, opts}})
  end

  def write(pid, data), do: GenServer.cast(pid, {:frame, ?i, data})
  def close(pid), do: GenServer.cast(pid, {:frame, ?e, ""})
  def signal(pid, n), do: GenServer.cast(pid, {:frame, ?k, <<n>>})

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init({vm, argv, owner, opts}) do
    Process.monitor(owner)
    path = Path.join([Weaver.Host.dir(), vm, "vsock.sock"])
    request = JSON.encode!(%{argv: argv, cwd: opts[:cwd] || "", env: opts[:env] || []})

    with {:ok, sock} <-
           :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: :line]),
         :ok <- :gen_tcp.send(sock, "CONNECT #{@port}\n"),
         {:ok, "OK " <> _} <- :gen_tcp.recv(sock, 0, 5000),
         :ok <- :inet.setopts(sock, packet: 4, active: true),
         :ok <- :gen_tcp.send(sock, [?x, request]) do
      {:ok, %{sock: sock, owner: owner}}
    else
      {:error, reason} -> {:stop, reason}
      other -> {:stop, {:handshake, other}}
    end
  end

  @impl true
  def handle_cast({:frame, type, data}, state) do
    :gen_tcp.send(state.sock, [type, data])
    {:noreply, state}
  end

  @impl true
  def handle_info({:tcp, _, <<?o, data::binary>>}, state), do: tell(state, {:data, :stdout, data})
  def handle_info({:tcp, _, <<?r, data::binary>>}, state), do: tell(state, {:data, :stderr, data})
  def handle_info({:tcp, _, <<?q, code::32>>}, state), do: last(state, {:exit_status, code})
  def handle_info({:tcp, _, <<?f, why::binary>>}, state), do: last(state, {:error, why})
  def handle_info({:tcp_closed, _}, state), do: last(state, {:error, :closed})
  def handle_info({:DOWN, _, :process, _, _}, state), do: {:stop, :normal, state}

  defp tell(state, msg) do
    send(state.owner, {self(), msg})
    {:noreply, state}
  end

  defp last(state, msg) do
    send(state.owner, {self(), msg})
    {:stop, :normal, state}
  end
end
