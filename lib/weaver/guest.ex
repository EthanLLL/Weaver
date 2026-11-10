defmodule Weaver.Guest do
  @moduledoc """
  Talking to `weaver-guest` in a VM on this host: one vsock connection per
  request, through Firecracker's Unix socket. Wire format: `guest/main.go`.
  """

  @port 1024

  @doc "A passive connection to `vm`'s guest, ready for a request frame."
  def connect(vm) do
    path = Path.join([Weaver.Host.dir(), vm, "vsock.sock"])

    with {:ok, sock} <-
           :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: :line]),
         :ok <- :gen_tcp.send(sock, "CONNECT #{@port}\n"),
         {:ok, "OK " <> _} <- :gen_tcp.recv(sock, 0, 5000),
         :ok <- :inet.setopts(sock, packet: 4) do
      {:ok, sock}
    else
      {:ok, other} -> {:error, {:handshake, other}}
      {:error, :enoent} -> {:error, :no_such_vm}
      {:error, :econnrefused} -> {:error, :vm_not_running}
      {:error, _} = e -> e
    end
  end

  @doc """
  A file operation in `vm` (see `guest/files.go` for each `op`).

  `read` gives `{:ok, binary}`; `list`, `stat` and `walk` `{:ok, entries}`,
  each `%{name, type, size, mtime}` with `type` an atom (`:file`, `:dir`,
  `:symlink`, `:other`) and `mtime` in Unix milliseconds; the others `:ok`.
  A missing path is `{:error, :enoent}`, a taken one `{:error, :eexist}`.

  Options: `data` (for `write`), `to` (for `rename`), `user` (who owns what
  the operation creates).
  """
  def file(vm, op, path, opts \\ [])
      when op in ~w(read write list stat walk rename remove mkdir) do
    request = %{op: op, path: path, to: opts[:to] || "", user: opts[:user] || ""}

    with {:ok, sock} <- connect(vm) do
      try do
        :ok = :gen_tcp.send(sock, [?F, JSON.encode!(request)])

        if op == "write" do
          for chunk <- chunks(IO.iodata_to_binary(opts[:data] || "")),
              do: :ok = :gen_tcp.send(sock, [?i, chunk])

          :ok = :gen_tcp.send(sock, "e")
        end

        case collect(sock, []) do
          {:ok, out} when op == "read" -> {:ok, out}
          {:ok, out} when op == "stat" -> {:ok, entry(JSON.decode!(out))}
          {:ok, out} when op in ~w(list walk) -> {:ok, Enum.map(JSON.decode!(out), &entry/1)}
          {:ok, _} -> :ok
          error -> error
        end
      after
        :gen_tcp.close(sock)
      end
    end
  end

  @doc """
  A connection that appends to `path` in `vm`, for `Weaver.FS.Log`: every
  `[?i, data]` frame sent on it is written and synced. Passive, as `connect/1`.
  """
  def open_append(vm, path, user) do
    with {:ok, sock} <- connect(vm),
         :ok <-
           :gen_tcp.send(sock, [
             ?F,
             JSON.encode!(%{op: "append", path: path, to: "", user: user || ""})
           ]) do
      {:ok, sock}
    end
  end

  defp entry(%{"name" => name, "type" => type, "size" => size, "mtime" => mtime}) do
    %{name: name, type: type(type), size: size, mtime: mtime}
  end

  defp type("file"), do: :file
  defp type("dir"), do: :dir
  defp type("symlink"), do: :symlink
  defp type(_), do: :other

  defp collect(sock, acc) do
    case :gen_tcp.recv(sock, 0, 60_000) do
      {:ok, <<?o, data::binary>>} -> collect(sock, [acc | data])
      {:ok, <<?q, 0::32>>} -> {:ok, IO.iodata_to_binary(acc)}
      {:ok, <<?f, "enoent">>} -> {:error, :enoent}
      {:ok, <<?f, "eexist">>} -> {:error, :eexist}
      {:ok, <<?f, why::binary>>} -> {:error, why}
      {:error, _} = e -> e
    end
  end

  defp chunks(<<chunk::binary-size(65_536), rest::binary>>), do: [chunk | chunks(rest)]
  defp chunks(rest), do: [rest]
end
