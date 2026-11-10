defmodule WeaverWeb.VncSocket do
  @moduledoc """
  The user's view of their tenant's browser: a WebSocket carrying VNC (RFB)
  to and from x11vnc in the tenant's VM, through `Weaver.Tunnel`. Bytes go
  through untouched; noVNC on the page speaks the protocol. Loom's, with the
  VNC server in a VM, maybe on another node.

  Opening it starts the browser (`Weaver.Browser.start/1`), and the socket
  waits for VNC to answer, trying again each second: the first start installs
  Chrome, so this can be a minute. noVNC waits for the server to speak first,
  so it just shows "connecting" meanwhile. What the page sends before then is
  kept and passed on once connected.

  x11vnc has no password and listens on the VM's loopback only, so this
  socket is the one way in; `WeaverWeb.BrowserController` lets it open only
  with a login token, for the tenant the host names.
  """
  @behaviour WebSock

  require Logger

  @retry 1_000
  @tries 180

  @impl true
  def init(t) do
    case Weaver.Browser.start(t) do
      :ok ->
        state = %{tenant: t, tunnel: nil, tries: 0, pending: [], up: false}
        {:ok, connect(state)}

      {:error, reason} ->
        Logger.warning("WeaverWeb.VncSocket #{t}: browser did not start: #{inspect(reason)}")
        {:stop, {:shutdown, reason}, {1011, "the browser could not be started"}, nil}
    end
  end

  defp connect(state) do
    case Weaver.Tunnel.open(state.tenant, Weaver.Browser.vnc_port()) do
      {:ok, pid} ->
        for data <- Enum.reverse(state.pending), do: Weaver.Tunnel.write(pid, data)
        %{state | tunnel: pid, tries: state.tries + 1}

      {:error, _} ->
        retry(%{state | tunnel: nil, tries: state.tries + 1})
    end
  end

  defp retry(state) do
    Process.send_after(self(), :connect, @retry)
    state
  end

  @impl true
  def handle_in({data, opcode: :binary}, %{tunnel: pid, up: true} = state) do
    Weaver.Tunnel.write(pid, data)
    {:ok, state}
  end

  def handle_in({data, opcode: :binary}, state) do
    if state.tunnel, do: Weaver.Tunnel.write(state.tunnel, data)
    {:ok, %{state | pending: [data | state.pending]}}
  end

  def handle_in(_text, state), do: {:ok, state}

  # One read at a time, acked once it has gone out: a slow client holds
  # x11vnc back rather than filling this mailbox.
  @impl true
  def handle_info({pid, {:data, data}}, %{tunnel: pid} = state) do
    Weaver.Tunnel.ack(pid)
    {:push, {:binary, data}, %{state | up: true, pending: []}}
  end

  def handle_info({pid, {:error, "econnrefused"}}, %{tunnel: pid, up: false} = state)
      when state.tries < @tries do
    {:ok, retry(%{state | tunnel: nil})}
  end

  def handle_info({pid, _}, %{tunnel: pid} = state) do
    {:stop, :normal, {1011, "the browser is not running"}, state}
  end

  def handle_info(:connect, %{tunnel: nil} = state), do: {:ok, connect(state)}
  def handle_info(_, state), do: {:ok, state}

  @impl true
  def terminate(_reason, %{tunnel: pid}) when is_pid(pid), do: Weaver.Tunnel.close(pid)
  def terminate(_reason, _), do: :ok
end
