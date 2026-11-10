defmodule WeaverWeb.AgentChannel do
  @moduledoc """
  One channel per attachment to a session (Loom's), for the socket's tenant.
  The session runs on the tenant's node; this channel may be anywhere, and
  hears it on the session's tenant-scoped topic. Attaching also keeps the
  session (and the tenant) up while the channel lives.

  Client → server: "submit", "interrupt", "drop_queued", "rename".
  Server → client: "event", "delta".
  """
  use Phoenix.Channel

  import WeaverWeb.At

  alias Weaver.Agent

  @impl true
  def join("agent:" <> id, params, socket) do
    t = socket.assigns.tenant
    since_seq = params |> Map.get("since_seq", 0) |> normalize_seq()

    # Subscribed before the snapshot, so nothing emitted in between is lost:
    # it arrives as a broadcast the client drops by seq.
    :ok = Phoenix.PubSub.subscribe(Weaver.PubSub, Agent.topic(t, id))

    case at(socket, Agent, :attach, [id, since_seq, self()]) do
      {:ok, snapshot} ->
        Weaver.Tenant.hold(t)

        {:ok, snapshot,
         socket
         |> assign(:session_id, id)
         |> assign(:device, Map.get(params, "device", "unknown"))}

      _ ->
        Phoenix.PubSub.unsubscribe(Weaver.PubSub, Agent.topic(t, id))
        {:error, %{reason: "unknown_session"}}
    end
  end

  @impl true
  def handle_in("submit", %{"text" => text} = params, socket) when is_binary(text) do
    opts = [
      origin: socket.assigns.device,
      client_msg_id: Map.get(params, "client_msg_id"),
      files: file_paths(params)
    ]

    case at(socket, Agent, :submit, [socket.assigns.session_id, text, opts]) do
      {:ok, disposition} -> {:reply, {:ok, %{status: disposition}}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  def handle_in("submit", _params, socket),
    do: {:reply, {:error, %{reason: "submit requires a `text` string"}}, socket}

  def handle_in("interrupt", _params, socket) do
    case at(socket, Agent, :interrupt, [socket.assigns.session_id]) do
      :ok -> {:reply, :ok, socket}
      {:error, reason} -> {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  def handle_in("drop_queued", %{"index" => index}, socket) when is_integer(index) do
    case at(socket, Agent, :drop_queued, [socket.assigns.session_id, index]) do
      :ok -> {:reply, :ok, socket}
      {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in("rename", %{"title" => title}, socket) when is_binary(title) do
    case at(socket, Agent, :rename, [socket.assigns.session_id, title]) do
      :ok -> {:reply, :ok, socket}
      {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  @impl true
  def handle_info({:agent_event, _id, event}, socket) do
    push(socket, "event", event)
    {:noreply, socket}
  end

  def handle_info({:agent_delta, _id, delta}, socket) do
    push(socket, "delta", delta)
    {:noreply, socket}
  end

  defp normalize_seq(seq) when is_integer(seq) and seq >= 0, do: seq
  defp normalize_seq(_), do: 0

  defp file_paths(%{"files" => files}) when is_list(files) do
    Enum.flat_map(files, fn
      %{"path" => path} when is_binary(path) -> [path]
      path when is_binary(path) -> [path]
      _ -> []
    end)
  end

  defp file_paths(_params), do: []
end
