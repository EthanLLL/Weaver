defmodule Weaver.Exec do
  @moduledoc """
  A process in a tenant VM, held by an Erlang process that stands in for a
  port: it talks to `weaver-guest` over the VM's vsock and sends its owner

    * `{pid, {:data, :stdout | :stderr, binary}}`
    * `{pid, {:exit_status, integer}}`, last
    * `{pid, {:error, reason}}`, last, if it could not run or the VM went away

  The owner may be on another node; that is the point. If the owner dies the
  connection closes, and the guest kills the process.

  Options: `user` (else root), `cwd` (else their home), `env` (`["K=V"]`), and `pty: {rows, cols}` for a terminal,
  whose output all comes as `:stdout`.
  """
  use GenServer, restart: :temporary

  @doc "Run `argv` in `vm` on this host, for `owner`."
  def start(vm, argv, owner \\ self(), opts \\ []) do
    DynamicSupervisor.start_child(Weaver.Execs, {__MODULE__, {vm, argv, owner, opts}})
  end

  @doc "Kill it: the connection closes, and the guest kills its process group."
  def stop(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Like `start/4`, from any node: on the node that has `vm`. The process is
  still the caller's, and goes when the caller does.
  """
  def start_anywhere(vm, argv, owner \\ self(), opts \\ []) do
    with {:ok, node} <- Weaver.Tenant.vm_node(vm) do
      if node == node(),
        do: start(vm, argv, owner, opts),
        else: :erpc.call(node, __MODULE__, :start, [vm, argv, owner, opts])
    end
  end

  @doc """
  Run `argv` in `vm`, from any node, and wait: `{:ok, %{stdout, stderr,
  status}}`. Past `timeout` it is killed, `{:error, :timeout}`.
  """
  def run(vm, argv, opts \\ [], timeout \\ 60_000) do
    with {:ok, pid} <- start_anywhere(vm, argv, self(), opts) do
      close(pid)
      collect(pid, [], [], timeout)
    end
  end

  defp collect(pid, out, err, timeout) do
    receive do
      {^pid, {:data, :stdout, d}} ->
        collect(pid, [out | d], err, timeout)

      {^pid, {:data, :stderr, d}} ->
        collect(pid, out, [err | d], timeout)

      {^pid, {:exit_status, s}} ->
        {:ok, %{stdout: IO.iodata_to_binary(out), stderr: IO.iodata_to_binary(err), status: s}}

      {^pid, {:error, why}} ->
        {:error, why}
    after
      timeout ->
        stop(pid)
        {:error, :timeout}
    end
  end

  def write(pid, data), do: GenServer.cast(pid, {:frame, ?i, data})
  def close(pid), do: GenServer.cast(pid, {:frame, ?e, ""})
  def signal(pid, n), do: GenServer.cast(pid, {:frame, ?k, <<n>>})
  def resize(pid, rows, cols), do: GenServer.cast(pid, {:frame, ?z, <<rows::16, cols::16>>})

  def start_link(arg), do: GenServer.start_link(__MODULE__, arg)

  @impl true
  def init({vm, argv, owner, opts}) do
    Process.monitor(owner)

    request =
      %{argv: argv, user: opts[:user] || "", cwd: opts[:cwd] || "", env: opts[:env] || []}
      |> then(fn r ->
        case opts[:pty] do
          {rows, cols} -> Map.put(r, :pty, %{rows: rows, cols: cols})
          nil -> r
        end
      end)

    with {:ok, sock} <- Weaver.Guest.connect(vm),
         :ok <- :gen_tcp.send(sock, [?x, JSON.encode!(request)]),
         :ok <- :inet.setopts(sock, active: true) do
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
