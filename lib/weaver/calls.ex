defmodule Weaver.Calls do
  @moduledoc """
  Programs in a VM calling Weaver (`weaver <method> [json]` in the guest).

  A guest that dials the host's vsock port 1025 reaches the Unix socket
  `vsock.sock_1025` beside the VM's own; one is listened on for each VM on
  this host. Which socket a call came in on is which tenant made it, so a
  call carries no credentials, and a method sees only its own tenant.

  Methods are the `call/3` clauses below and nothing else, and `node.*`,
  which stream and are `Weaver.Calls.Node`'s.
  """
  use GenServer

  require Logger

  @port 1025

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "Listen for `vm`'s calls, if not already."
  def ensure(vm), do: GenServer.call(__MODULE__, {:ensure, vm})

  # The methods: what a program in the VM may ask of Weaver, and nothing more.
  # `tenant` is the VM the call came from; a method sees only that tenant.
  defp call(tenant, "whoami", _args), do: {:ok, %{tenant: tenant, host: node()}}
  defp call(_tenant, "echo", args), do: {:ok, args}

  # Sessions, for the `sessions` skill: work started in parallel, watched in
  # the sidebar.
  defp call(t, "sessions.list", _args) do
    {:ok,
     for(
       s <- Weaver.Tenant.sessions(t),
       do: Map.take(s, [:id, :title, :directory, :status, :backend, :last_active_at])
     )}
  end

  defp call(t, "sessions.new", %{"title" => title, "prompt" => prompt} = args)
       when is_binary(title) and is_binary(prompt) do
    with {:ok, backend} <- backend(args["backend"]),
         {:ok, id} <-
           agent(t, :new_session, [title, prompt, [backend: backend, origin: "weaver"]]) do
      {:ok, %{id: id}}
    end
  end

  defp call(_t, "sessions.new", _args),
    do: {:error, ~s(want {"title": "…", "prompt": "…", "backend"?: "claude_code" | "codex"})}

  defp call(t, "sessions.submit", %{"id" => id, "text" => text})
       when is_binary(id) and is_binary(text) do
    with {:ok, disposition} <- agent(t, :submit, [id, text, [origin: "weaver"]]),
         do: {:ok, %{status: disposition}}
  end

  defp call(t, "sessions.status", %{"id" => id}) when is_binary(id) do
    with %{} = info <- agent(t, :info, [id]),
         do: {:ok, Map.take(info, [:id, :title, :status, :queued, :turns])}
  end

  # The newest reply, and whether the turn that wrote it is over.
  defp call(t, "sessions.reply", %{"id" => id}) when is_binary(id) do
    with {:ok, %{meta: meta, events: events}} <- agent(t, :attach, [id, 0, nil]) do
      text =
        events
        |> Enum.filter(&(&1.kind == :assistant_text))
        |> List.last()
        |> then(&(&1 && &1.payload.text))

      {:ok, %{status: meta.status, reply: text}}
    end
  end

  defp call(t, "sessions.interrupt", %{"id" => id}) when is_binary(id) do
    with :ok <- agent(t, :interrupt, [id]), do: {:ok, %{}}
  end

  defp call(t, "sessions.delete", %{"id" => id}) when is_binary(id) do
    with :ok <- agent(t, :delete_session, [id]), do: {:ok, %{}}
  end

  defp call(_tenant, method, _args), do: {:error, "no such method or bad arguments: #{method}"}

  defp backend(nil), do: {:ok, :claude_code}

  defp backend(name) do
    case Weaver.Agent.Backend.parse(name) do
      {:ok, backend} -> {:ok, backend}
      :error -> {:error, "backend is claude_code or codex"}
    end
  end

  defp agent(t, fun, args) do
    case Weaver.Tenant.at(t, Weaver.Agent, fun, [t | args]) do
      {:error, reason} -> {:error, if(is_binary(reason), do: reason, else: inspect(reason))}
      other -> other
    end
  end

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
      case method do
        # Streams both ways, for as long as the request runs.
        "node." <> _ -> Weaver.Calls.Node.serve(sock, vm, method, req["args"] || %{})
        _ -> reply(sock, vm, method, req["args"] || %{})
      end
    else
      _ -> :gen_tcp.send(sock, [?f, "bad call"])
    end

    :gen_tcp.close(sock)
  end

  defp reply(sock, vm, method, args) do
    case call(vm, method, args) do
      {:ok, reply} ->
        :gen_tcp.send(sock, [?o, JSON.encode!(reply)]) && :gen_tcp.send(sock, <<?q, 0::32>>)

      {:error, why} ->
        :gen_tcp.send(sock, [?f, why])
    end
  end
end
