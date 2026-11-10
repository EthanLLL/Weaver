defmodule Weaver.Terminal.Session do
  @moduledoc """
  Owns a single PTY running a shell: in Weaver, a login shell in the tenant's
  VM as its user, through `Weaver.Exec` (ported from Loom, where it is ExPTY
  on the host). Decoupled from any websocket:
  the PTY keeps running even if the browser disconnects, so a client can leave
  and later reattach to the same live shell.

  Every attached client (one channel per browser tab) receives
  `{:pty_output, binary}`. Recent output is kept in a bounded ring buffer and
  replayed to a client on attach, so a reconnecting client sees the current
  screen instead of blank.

  ## Several clients, one shell

  Input needs nothing special: every keystroke frame is a cast into this
  process, so two people typing at once interleave frame by frame — like two
  hands on one keyboard — and no frame is ever split.

  What does need care is that a PTY has one of everything a terminal has, and
  each client is a whole terminal:

    * **One size.** A phone at 40 columns and a laptop at 200 cannot both be
      right. The size follows the *driver*, the client that most recently
      typed — tmux's `window-size latest`. Whoever is using the shell sees it
      laid out correctly; a client that is only watching may see it wrap.
    * **One reply per query.** A TUI asks the terminal things (cursor position,
      device attributes, colours) and every xterm.js attached answers. A second
      answer arrives as stray input — `^[[12;1R` printed at the prompt. So a
      frame made only of such replies is dropped unless it comes from the
      driver, and does not make its sender the driver.

  Replay is sent from inside the attach call, so nothing the shell prints can
  land between the buffer and the live stream — which is why clients are kept
  here rather than on a PubSub topic, where subscribing and fetching the buffer
  are two steps with output in between.
  """
  use GenServer, restart: :transient

  require Logger

  # Bytes of recent output retained for replay-on-reconnect.
  @buffer_limit 256 * 1024

  # ── Public API ──────────────────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts,
      name: via(Keyword.fetch!(opts, :tenant), Keyword.fetch!(opts, :id))
    )
  end

  @doc """
  Attach `pid` as a client, `size` being its `{cols, rows}` if known.

  Immediately replays the retained output buffer to `pid` (as a
  `{:pty_output, binary}`) so it can rebuild the screen. The newcomer becomes
  the driver: whoever just opened a terminal is the one about to use it.
  """
  def subscribe(t, id, pid, size \\ nil), do: GenServer.call(via(t, id), {:subscribe, pid, size})

  @doc "Send raw keystrokes from client `pid` to the shell's stdin."
  def send_input(t, id, pid, data), do: GenServer.cast(via(t, id), {:input, pid, data})

  @doc """
  Record client `pid`'s size. Resizes the PTY (SIGWINCH) only if `pid` is the
  driver, or nobody is.
  """
  def resize(t, id, pid, cols, rows), do: GenServer.cast(via(t, id), {:resize, pid, cols, rows})

  @doc "Return metadata about the session."
  def info(t, id), do: GenServer.call(via(t, id), :info)

  def via(t, id), do: {:via, Registry, {Weaver.Local, {:terminal, t, id}}}

  # ── GenServer ───────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    t = Keyword.fetch!(opts, :tenant)
    id = Keyword.fetch!(opts, :id)
    cols = Keyword.get(opts, :cols, 80)
    rows = Keyword.get(opts, :rows, 24)
    title = Keyword.get(opts, :title)

    {:ok, pty} =
      Weaver.Exec.start(t, ["bash", "-l"], self(),
        user: Weaver.FS.user(),
        pty: {rows, cols},
        env: ["COLORTERM=truecolor"]
      )

    state = %{
      tenant: t,
      id: id,
      pty: pty,
      title: title,
      created_at: System.system_time(:millisecond),
      cols: cols,
      rows: rows,
      # pid => %{ref: monitor, size: {cols, rows} | nil}
      clients: %{},
      driver: nil,
      buffer: "",
      buffer_size: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, pid, size}, _from, state) do
    client =
      case state.clients do
        %{^pid => client} -> %{client | size: size || client.size}
        _ -> %{ref: Process.monitor(pid), size: size}
      end

    # Replay retained output so the client rebuilds the current screen.
    if state.buffer_size > 0, do: send(pid, {:pty_output, state.buffer})

    state = put_in(state.clients[pid], client)
    {:reply, :ok, drive(state, pid)}
  end

  def handle_call(:info, _from, state) do
    {:reply, session_info(state), state}
  end

  @impl true
  def handle_cast({:input, pid, data}, state) do
    cond do
      pid == state.driver ->
        Weaver.Exec.write(state.pty, data)
        {:noreply, state}

      reply_only?(data) ->
        {:noreply, state}

      true ->
        Weaver.Exec.write(state.pty, data)
        {:noreply, drive(state, pid)}
    end
  end

  def handle_cast({:resize, pid, cols, rows}, state) do
    case state.clients do
      %{^pid => _} ->
        state = put_in(state.clients[pid].size, {cols, rows})
        if state.driver in [nil, pid], do: {:noreply, drive(state, pid)}, else: {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({pty, {:data, _, data}}, %{pty: pty} = state) do
    output = Weaver.Terminal.Sgr.transform(data)

    if output == "" do
      {:noreply, state}
    else
      for {pid, _} <- state.clients, do: send(pid, {:pty_output, output})
      {:noreply, append_buffer(state, output)}
    end
  end

  def handle_info({pty, {kind, _}}, %{pty: pty} = state) when kind in [:exit_status, :error] do
    Logger.info("Shell for terminal #{state.tenant}/#{state.id} exited, stopping")
    {:stop, :normal, state}
  end

  # A client went away — keep the PTY alive for reconnect. If it was driving,
  # hand the wheel to someone still here, so the size fits a screen that is
  # actually looking at it.
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state)
      when is_map_key(state.clients, pid) do
    {_, clients} = Map.pop(state.clients, pid)
    state = %{state | clients: clients}

    cond do
      state.driver != pid -> {:noreply, state}
      clients == %{} -> {:noreply, %{state | driver: nil}}
      true -> {:noreply, drive(state, clients |> Map.keys() |> hd())}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Closing the connection kills the shell's process group in the VM.
    Weaver.Exec.stop(state.pty)
    :ok
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  # Make `pid` the driver and fit the PTY to it.
  defp drive(state, pid) do
    case state.clients[pid] do
      %{size: {cols, rows}} when {cols, rows} != {state.cols, state.rows} ->
        Weaver.Exec.resize(state.pty, rows, cols)
        %{state | driver: pid, cols: cols, rows: rows}

      _ ->
        %{state | driver: pid}
    end
  end

  # What xterm.js sends on its own, answering the program rather than the
  # user: cursor position and status reports (CSI … R / n), device attributes
  # (CSI ? … c, CSI > … c), mode reports (CSI … $ y), window reports (CSI … t),
  # keyboard protocol (CSI ? … u), focus in/out (CSI I / O), OSC replies such as
  # colours, and DCS replies such as XTGETTCAP. Only frames made *entirely* of
  # these count, so a keystroke is never dropped — the one overlap, Ctrl+F3
  # also being CSI 1;5 R, is lost only from a client that is not driving.
  @reply ~r/\A(?:\e\[\??[\d;]*[Rn]|\e\[[\d;]*t|\e\[[?>=][\d;]*c|\e\[\?[\d;]*u|\e\[\??[\d;]*\$y|\e\[[IO]|\e\][^\a\e]*(?:\a|\e\\)|\eP[^\e]*\e\\)+\z/

  defp reply_only?(data), do: Regex.match?(@reply, data)

  defp append_buffer(state, output) do
    buffer = state.buffer <> output
    size = state.buffer_size + byte_size(output)

    if size > @buffer_limit do
      # Keep the most recent @buffer_limit bytes. A stray partial escape at the
      # new front is harmless — xterm ignores it during replay.
      trimmed = binary_part(buffer, size - @buffer_limit, @buffer_limit)
      %{state | buffer: trimmed, buffer_size: @buffer_limit}
    else
      %{state | buffer: buffer, buffer_size: size}
    end
  end

  defp session_info(state) do
    %{
      id: state.id,
      title: state.title,
      created_at: state.created_at,
      cols: state.cols,
      rows: state.rows
    }
  end
end
