defmodule Weaver.Session do
  @moduledoc """
  A Claude Code conversation in a tenant's VM, driven from wherever this
  process runs: `claude -p` in stream-json, through `Weaver.Exec`.

  The conversation is the VM's: Claude Code keeps it under the user's
  `~/.claude/projects/` there, and `resume:` picks it up again; this process
  holds nothing that can't be lost. How Claude Code reaches a model is the
  tenant's own configuration in the VM; nothing about it passes through here.

  The owner gets `{pid, {:event, map}}` for every line Claude Code prints
  and `{pid, {:exit, status | reason}}` at the end.
  """
  use GenServer

  require Logger

  @claude "/home/tenant/.local/bin/claude"
  @args ~w(-p --verbose --input-format stream-json --output-format stream-json
           --setting-sources user --permission-mode bypassPermissions)

  @doc "Start a conversation (or `resume:` one by id) in `tenant`'s VM, as `user:` (default `tenant`)."
  def start(tenant, opts \\ []) do
    GenServer.start(__MODULE__, {tenant, self(), opts})
  end

  @doc "Send the user's next message."
  def say(pid, text), do: GenServer.cast(pid, {:say, text})

  def stop(pid), do: GenServer.stop(pid)

  @impl true
  def init({tenant, owner, opts}) do
    Process.monitor(owner)
    session = opts[:resume] || uuid4()
    args = @args ++ if(opts[:resume], do: ["--resume", session], else: ["--session-id", session])

    with {:ok, node} <- Weaver.where(tenant),
         {:ok, exec} <-
           :erpc.call(node, Weaver.Exec, :start, [
             tenant,
             [@claude | args],
             self(),
             [user: opts[:user] || "tenant"]
           ]) do
      {:ok, %{exec: exec, owner: owner, buffer: "", session: session}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_cast({:say, text}, state) do
    line = JSON.encode!(%{type: "user", message: %{role: "user", content: text}})
    Weaver.Exec.write(state.exec, line <> "\n")
    {:noreply, state}
  end

  @impl true
  def handle_info({exec, {:data, :stdout, data}}, %{exec: exec} = state) do
    [rest | lines] = String.split(state.buffer <> data, "\n") |> Enum.reverse()

    for line <- Enum.reverse(lines), line != "" do
      case JSON.decode(line) do
        {:ok, event} -> send(state.owner, {self(), {:event, event}})
        {:error, _} -> Logger.warning("Weaver.Session: not JSON: #{inspect(line)}")
      end
    end

    {:noreply, %{state | buffer: rest}}
  end

  def handle_info({exec, {:data, :stderr, data}}, %{exec: exec} = state) do
    Logger.info("Weaver.Session stderr: #{String.trim(data)}")
    {:noreply, state}
  end

  def handle_info({exec, {:exit_status, status}}, %{exec: exec} = state) do
    send(state.owner, {self(), {:exit, status}})
    {:stop, :normal, state}
  end

  def handle_info({exec, {:error, reason}}, %{exec: exec} = state) do
    send(state.owner, {self(), {:exit, reason}})
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, _, :process, _, _}, state), do: {:stop, :normal, state}

  defp uuid4 do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    <<u::128>> = <<a::48, 4::4, b::12, 2::2, c::62>>
    hex = u |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(32, "0")
    <<p1::binary-8, p2::binary-4, p3::binary-4, p4::binary-4, p5::binary-12>> = hex
    Enum.join([p1, p2, p3, p4, p5], "-")
  end
end
