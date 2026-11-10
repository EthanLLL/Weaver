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
  A file operation in `vm`: `read` gives `{:ok, binary}`, `list` and `stat`
  `{:ok, decoded JSON}`, `write` (with `data`), `remove` and `mkdir` `:ok`.
  A missing path is `{:error, :enoent}`.
  """
  def file(vm, op, path, data \\ nil) when op in ~w(read write list stat remove mkdir) do
    with {:ok, sock} <- connect(vm) do
      try do
        :ok = :gen_tcp.send(sock, [?F, JSON.encode!(%{op: op, path: path})])

        if op == "write" do
          for chunk <- chunks(IO.iodata_to_binary(data)),
              do: :ok = :gen_tcp.send(sock, [?i, chunk])

          :ok = :gen_tcp.send(sock, "e")
        end

        collect(sock, [])
        |> case do
          {:ok, out} when op == "read" -> {:ok, out}
          {:ok, out} when op in ~w(list stat) -> {:ok, JSON.decode!(out)}
          {:ok, _} -> :ok
          error -> error
        end
      after
        :gen_tcp.close(sock)
      end
    end
  end

  defp collect(sock, acc) do
    case :gen_tcp.recv(sock, 0, 30_000) do
      {:ok, <<?o, data::binary>>} -> collect(sock, [acc | data])
      {:ok, <<?q, 0::32>>} -> {:ok, IO.iodata_to_binary(acc)}
      {:ok, <<?f, "enoent">>} -> {:error, :enoent}
      {:ok, <<?f, why::binary>>} -> {:error, why}
      {:error, _} = e -> e
    end
  end

  defp chunks(<<chunk::binary-size(65_536), rest::binary>>), do: [chunk | chunks(rest)]
  defp chunks(rest), do: [rest]
end
