defmodule Weaver.Peers do
  @moduledoc """
  Keeps this node connected to the other hosts, named in `WEAVER_PEERS`
  (comma-separated node names). Connecting is idempotent, so it simply tries
  every few seconds; a host that comes back rejoins on its own.
  """
  use GenServer

  @every :timer.seconds(5)

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    peers =
      (System.get_env("WEAVER_PEERS") || "")
      |> String.split(",", trim: true)
      |> Enum.map(&String.to_atom/1)
      |> Enum.reject(&(&1 == node()))

    send(self(), :connect)
    {:ok, peers}
  end

  @impl true
  def handle_info(:connect, peers) do
    if Node.alive?(), do: Enum.each(peers, &Node.connect/1)
    Process.send_after(self(), :connect, @every)
    {:noreply, peers}
  end
end
