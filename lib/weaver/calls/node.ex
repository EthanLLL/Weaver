defmodule Weaver.Calls.Node do
  @moduledoc """
  `weaver node list | exec | read | write` from a program in the VM
  (`guest/node.go`): Loom's `LoomWeb.NodeController`, over the call
  connection instead of HTTP. The connection is the request and, for as long
  as it lasts, its stream:

    * `node.list`: one `o` frame, the devices as JSON, then `q`.
    * `node.exec` `{node, cmd, cwd, timeout, session}`: the command's stdout
      as `o` frames and stderr as `r`, then `q` with its exit status (124 if
      it was killed for running past `timeout`).
    * `node.read` `{node, path}`: the file as `o` frames, then `q`.
    * `node.write` `{node, path}`: the guest sends the file as `i` frames,
      then `e`; one `o` frame `{size, path}` answers, then `q`.

  `f` with a message, worded for the model that reads it, if Weaver could
  not do it: the device is unknown, offline, or dropped mid-request.

  The connection closing (the CLI was interrupted) cancels the request on the
  device; the device dropping is the channel's `:DOWN`.
  """

  alias Weaver.Nodes

  # How long an offline device gets to come back.
  @await_ms 10_000
  @default_timeout 120
  @max_timeout 1_800
  # Beyond the device's own deadline (`timeout` plus its kill grace), how long
  # to wait for the device to say so before giving up on it.
  @slack_ms 30_000
  @chunk 256 * 1024
  @max_write 100 * 1024 * 1024

  @retry_hint "run `weaver node list` to see whether it is back online, then retry"

  def serve(sock, t, "node.list", _args) do
    :gen_tcp.send(sock, [?o, JSON.encode!(Nodes.list(t))])
    :gen_tcp.send(sock, <<?q, 0::32>>)
  end

  def serve(sock, t, "node.exec", %{"node" => name, "cmd" => cmd} = args) when is_binary(cmd) do
    timeout = clamp_timeout(args["timeout"])

    payload = %{
      "cmd" => cmd,
      "cwd" => args["cwd"],
      "timeout" => timeout,
      "session" => args["session"]
    }

    with_node(sock, t, name, fn pid ->
      stream(sock, pid, "exec", payload, timeout * 1000 + @slack_ms, timeout)
    end)
  end

  def serve(sock, t, "node.read", %{"node" => name, "path" => path}) when is_binary(path) do
    with_node(sock, t, name, fn pid ->
      stream(sock, pid, "read", %{"path" => path}, :timer.minutes(10), nil)
    end)
  end

  def serve(sock, t, "node.write", %{"node" => name, "path" => path}) when is_binary(path) do
    with_node(sock, t, name, fn pid ->
      ref = Process.monitor(pid)
      upload(sock, pid, ref, request_id(), path, [], 0, 0)
    end)
  end

  def serve(sock, _t, method, _args), do: fail(sock, "bad arguments for #{method}")

  # ── Streaming ───────────────────────────────────────────────────────────

  defp stream(sock, pid, event, payload, limit_ms, timeout) do
    id = request_id()
    ref = Process.monitor(pid)
    send(pid, {:node_send, self(), id, event, payload})
    # Only to hear the guest hang up.
    :inet.setopts(sock, active: :once)
    relay(sock, pid, ref, id, System.monotonic_time(:millisecond) + limit_ms, timeout)
  end

  defp relay(sock, pid, ref, id, deadline, timeout) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:node_reply, ^id, "out", %{"stream" => stream, "data" => data}} ->
        :gen_tcp.send(sock, [if(stream == "stderr", do: ?r, else: ?o), Base.decode64!(data)])
        relay(sock, pid, ref, id, deadline, timeout)

      {:node_reply, ^id, "chunk", %{"data" => data}} ->
        :gen_tcp.send(sock, [?o, Base.decode64!(data)])
        relay(sock, pid, ref, id, deadline, timeout)

      {:node_reply, ^id, "exit", payload} ->
        Process.demonitor(ref, [:flush])

        if payload["truncated"] == true,
          do:
            :gen_tcp.send(sock, [
              ?r,
              "\n[weaver node: output truncated at 10 MB of #{payload["bytes"]} bytes]\n"
            ])

        if payload["timed_out"] == true do
          :gen_tcp.send(sock, [
            ?r,
            "\n[weaver node: killed after #{timeout}s; pass a larger --timeout if it needs longer]\n"
          ])

          :gen_tcp.send(sock, <<?q, 124::32>>)
        else
          code = if is_integer(payload["code"]), do: payload["code"], else: 0
          :gen_tcp.send(sock, <<?q, code::32>>)
        end

      {:node_reply, ^id, "done", _payload} ->
        Process.demonitor(ref, [:flush])
        :gen_tcp.send(sock, <<?q, 0::32>>)

      {:node_reply, ^id, "error", payload} ->
        Process.demonitor(ref, [:flush])
        fail(sock, payload["message"] || "the device refused")

      {:DOWN, ^ref, :process, _pid, _reason} ->
        fail(sock, lost_message())

      {:tcp_closed, ^sock} ->
        cancel(pid, ref, id)

      {:tcp, ^sock, _} ->
        :inet.setopts(sock, active: :once)
        relay(sock, pid, ref, id, deadline, timeout)
    after
      remaining ->
        cancel(pid, ref, id)
        fail(sock, "the device stopped answering")
    end
  end

  # The file comes from the guest in frames of up to 64 KB; it goes on to
  # the device in chunks of `@chunk`.
  defp upload(sock, pid, ref, id, path, buffer, buffered, sent) do
    case :gen_tcp.recv(sock, 0, 60_000) do
      {:ok, <<?i, data::binary>>} ->
        buffered = buffered + byte_size(data)
        buffer = [buffer | data]

        cond do
          sent + buffered > @max_write ->
            cancel(pid, ref, id)
            fail(sock, "a write is capped at 100 MB")

          buffered >= @chunk ->
            with :ok <- push_chunk(sock, pid, ref, id, path, buffer, false),
                 do: upload(sock, pid, ref, id, path, [], 0, sent + buffered)

          true ->
            upload(sock, pid, ref, id, path, buffer, buffered, sent)
        end

      {:ok, "e"} ->
        with :ok <- push_chunk(sock, pid, ref, id, path, buffer, true),
             do: await_written(sock, ref, id)

      _ ->
        cancel(pid, ref, id)
    end
  end

  defp push_chunk(sock, pid, ref, id, path, buffer, final) do
    data = IO.iodata_to_binary(buffer)

    send(
      pid,
      {:node_send, self(), id, "write",
       %{"path" => path, "data" => Base.encode64(data), "final" => final}}
    )

    # The device may already have refused (a directory, no permission); no
    # point sending it the rest.
    receive do
      {:node_reply, ^id, "error", payload} ->
        Process.demonitor(ref, [:flush])
        fail(sock, payload["message"])

      {:DOWN, ^ref, :process, _pid, _reason} ->
        fail(sock, lost_message())
    after
      0 -> :ok
    end
  end

  defp await_written(sock, ref, id) do
    receive do
      {:node_reply, ^id, "written", payload} ->
        Process.demonitor(ref, [:flush])
        :gen_tcp.send(sock, [?o, JSON.encode!(payload)])
        :gen_tcp.send(sock, <<?q, 0::32>>)

      {:node_reply, ^id, "error", payload} ->
        Process.demonitor(ref, [:flush])
        fail(sock, payload["message"])

      {:DOWN, ^ref, :process, _pid, _reason} ->
        fail(sock, lost_message())
    after
      @slack_ms -> fail(sock, "the device did not confirm the write")
    end
  end

  defp lost_message,
    do:
      "the device disconnected during the request; anything it was running was killed there; " <>
        @retry_hint

  defp cancel(pid, ref, id) do
    Process.demonitor(ref, [:flush])
    send(pid, {:node_cancel, id})
  end

  defp fail(sock, message), do: :gen_tcp.send(sock, [?f, message])

  # ── Lookup ──────────────────────────────────────────────────────────────

  defp with_node(sock, t, name, fun) when is_binary(name) do
    case Nodes.await(t, name, @await_ms) do
      {:ok, pid} ->
        fun.(pid)

      {:offline, node} ->
        seen = if node.last_seen_at, do: "last seen #{node.last_seen_at}", else: "never connected"
        fail(sock, "#{node.name} is offline (#{seen}); #{@retry_hint}")

      :unknown ->
        names = Nodes.list(t) |> Enum.map_join(", ", & &1.name)

        known =
          if names == "",
            do: "no devices are registered; the user adds them under Devices in Weaver's sidebar",
            else: "devices: #{names}"

        fail(sock, "no device called #{name}; #{known}")
    end
  end

  defp with_node(sock, _t, _name, _fun), do: fail(sock, "a device name is required")

  defp clamp_timeout(t) when is_integer(t) and t > 0, do: min(t, @max_timeout)
  defp clamp_timeout(_), do: @default_timeout

  defp request_id, do: Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
end
