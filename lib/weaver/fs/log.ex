defmodule Weaver.FS.Log do
  @moduledoc """
  An append-only file in a tenant's VM, held open: one guest connection that
  writes and syncs every line it is sent. What `events.jsonl` is written
  through, a line per event, without a connection per line.

  Linked to whoever opened it. If the connection goes (the VM stopped), the
  log stops too; `append/2` to a log that has gone is a no-op that says so,
  as losing a line is survivable (see `Weaver.Agent.Store`).
  """
  use GenServer

  require Logger

  def open(t, path, user) do
    GenServer.start_link(__MODULE__, {t, path, user})
  end

  def append(nil, _data), do: :ok

  def append(pid, data) do
    if Process.alive?(pid) do
      GenServer.cast(pid, {:append, data})
    else
      Logger.error("Weaver.FS.Log: append to a closed log dropped")
    end

    :ok
  end

  def close(nil), do: :ok

  def close(pid) do
    GenServer.stop(pid, :normal)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init({t, path, user}) do
    case Weaver.Guest.open_append(t, path, user) do
      {:ok, sock} ->
        :inet.setopts(sock, active: true)
        {:ok, %{sock: sock, path: path}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_cast({:append, data}, state) do
    :gen_tcp.send(state.sock, [?i, data])
    {:noreply, state}
  end

  @impl true
  def handle_info({:tcp, _, <<?f, why::binary>>}, state) do
    Logger.error("Weaver.FS.Log #{state.path}: #{why}")
    {:stop, :normal, state}
  end

  def handle_info({:tcp_closed, _}, state), do: {:stop, :normal, state}
  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # End of input: the guest syncs and closes the file.
    :gen_tcp.send(state.sock, "e")
    :gen_tcp.close(state.sock)
  end
end
