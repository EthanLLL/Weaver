defmodule Weaver.Push do
  @moduledoc """
  Notifications on the user's devices when a turn is over: Loom's
  `Loom.Push`, one per tenant, in the tenant's tree (`Weaver.Tenant.Tree`).

  - **The key is the platform's.** The VAPID key pair push services check
    the sender by is one for all of Weaver (`config :weaver, Weaver.Push`,
    from `/etc/weaver/weaver.env`), like the endpoint's secret: it says
    "Weaver sent this", and never goes into a VM. A subscription is still
    only good for the origin it was made on, a tenant's own host.
  - **Subscriptions** are platform data, in `push_subscriptions` (this
    process keeps its tenant's in memory, read at start). Each links back to
    the host it was made on: the tenant's, taken from the request, not from
    what the browser says.
  - **What is sent**, and **not to a device that is looking**: as in Loom. A
    session broadcasts `{:turn_ended, id, summary}` on
    `Weaver.Tenant.turns_topic/1`; a device showing a session says so on the
    lobby channel (`watching/4`), held in memory against the channel's pid,
    which may be on another node.

  It does not hold the tenant up: a turn ends only in a running session,
  which does, and a device watching does so through its lobby channel.

  A push service that answers 404 or 410 has dropped the subscription, and
  so do we.
  """
  use GenServer

  import Ecto.Query

  require Logger

  alias Weaver.Push.WebPush
  alias Weaver.Repo
  alias Weaver.Tenant

  @body_limit 180

  def start_link(t), do: GenServer.start_link(__MODULE__, t, name: Tenant.via(t, :push))

  @doc "The platform's VAPID keys, raw, or `nil` when not configured."
  def keys do
    case Application.get_env(:weaver, __MODULE__, []) do
      [public: public, private: private] when is_binary(public) and is_binary(private) ->
        %{public: WebPush.decode!(public), private: WebPush.decode!(private)}

      _ ->
        nil
    end
  end

  @doc "The VAPID public key, base64url, which a browser subscribes with; `nil` if none."
  def public_key, do: Application.get_env(:weaver, __MODULE__, [])[:public]

  # Each of these runs on the tenant's node; callers go through `Tenant.at/4`.

  @doc """
  Keep a browser's subscription (`PushSubscription.toJSON()`, string keys),
  made on `origin`. With `test: true` it is sent a notification at once.
  """
  def subscribe(t, subscription, origin, test),
    do: GenServer.call(Tenant.via(t, :push), {:subscribe, subscription, origin, test})

  def unsubscribe(t, endpoint), do: GenServer.call(Tenant.via(t, :push), {:unsubscribe, endpoint})

  def list(t), do: GenServer.call(Tenant.via(t, :push), :list)

  @doc """
  The device subscribed at `endpoint` is showing `session_id` (`nil`: none,
  or it is hidden), as told by the channel process `pid`.
  """
  def watching(t, endpoint, session_id, pid),
    do: GenServer.cast(Tenant.via(t, :push), {:watching, endpoint, session_id, pid})

  # ── Server ──────────────────────────────────────────────────────────────

  @impl true
  def init(t) do
    Phoenix.PubSub.subscribe(Weaver.PubSub, Tenant.turns_topic(t))

    {:ok,
     %{
       tenant: t,
       subs: load(t),
       # endpoint => {session_id, pid, monitor}
       watching: %{}
     }}
  end

  @impl true
  def handle_call(:list, _from, state), do: {:reply, Map.values(state.subs), state}

  def handle_call({:subscribe, subscription, origin, test}, _from, state) do
    case parse(subscription, origin) do
      {:ok, sub} ->
        state = keep(state, sub)
        if test, do: send_to(sub, message(sub, "Weaver", "Notifications are on.", nil))
        {:reply, :ok, state}

      :error ->
        {:reply, {:error, :invalid}, state}
    end
  end

  def handle_call({:unsubscribe, endpoint}, _from, state), do: {:reply, :ok, drop(state, endpoint)}

  @impl true
  def handle_cast({:watching, endpoint, session_id, pid}, state) do
    {previous, watching} = Map.pop(state.watching, endpoint)
    if previous, do: Process.demonitor(elem(previous, 2), [:flush])

    watching =
      if is_binary(session_id),
        do: Map.put(watching, endpoint, {session_id, pid, Process.monitor(pid)}),
        else: watching

    {:noreply, %{state | watching: watching}}
  end

  def handle_cast({:gone, endpoint}, state) do
    Logger.info("Weaver.Push #{state.tenant}: #{endpoint} is gone; dropping it")
    {:noreply, drop(state, endpoint)}
  end

  @impl true
  def handle_info({:turn_ended, id, summary}, state) do
    {title, body} = describe(summary)

    for {endpoint, sub} <- state.subs, not looking?(state, endpoint, id) do
      send_to(sub, message(sub, title, body, id))
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    watching = Map.reject(state.watching, fn {_, {_, _, r}} -> r == ref end)
    {:noreply, %{state | watching: watching}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ── Sending ─────────────────────────────────────────────────────────────

  defp looking?(state, endpoint, id), do: match?({^id, _, _}, state.watching[endpoint])

  defp describe(%{title: title, outcome: outcome}) do
    body =
      case outcome do
        {:ok, text} when is_binary(text) and text != "" -> snippet(text)
        {:error, message} -> "Failed: " <> snippet(message)
        _ -> "Done."
      end

    {title || "Weaver", body}
  end

  # Markdown read as plain text: a notification shows a line or two.
  defp snippet(text) do
    text
    |> String.replace(~r/```[^\n]*\n?/, "")
    |> String.replace(~r/[*_`#>|]+/, "")
    |> String.replace(~r/\[([^\]]*)\]\([^)]*\)/, "\\1")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> truncate()
  end

  defp truncate(text) do
    if String.length(text) > @body_limit,
      do: String.slice(text, 0, @body_limit - 1) <> "…",
      else: text
  end

  defp message(sub, title, body, session_id) do
    url = if session_id, do: "#{sub.origin}/?session=#{session_id}", else: sub.origin <> "/"

    Jason.encode!(%{
      web_push: 8030,
      notification: %{
        title: title,
        body: body,
        navigate: url,
        # One notification per session: a newer turn replaces the older one.
        tag: session_id || "weaver",
        data: %{session: session_id}
      }
    })
  end

  defp send_to(sub, payload) do
    server = self()

    case keys() do
      nil ->
        Logger.warning("Weaver.Push: no VAPID keys configured; not sending")

      keys ->
        Task.start(fn ->
          case WebPush.deliver(sub, payload, keys, sub.origin) do
            {:ok, status, _body} when status in 200..299 ->
              :ok

            {:ok, status, _body} when status in [404, 410] ->
              GenServer.cast(server, {:gone, sub.endpoint})

            other ->
              Logger.warning("Weaver.Push: #{sub.endpoint} answered #{inspect(other)}")
          end
        end)
    end
  end

  # ── Storage ─────────────────────────────────────────────────────────────

  defp parse(
         %{
           "endpoint" => "https://" <> _ = endpoint,
           "keys" => %{"p256dh" => p256dh, "auth" => auth}
         },
         "https://" <> _ = origin
       )
       when is_binary(p256dh) and is_binary(auth) do
    with {:ok, _} <- Base.url_decode64(String.trim_trailing(p256dh, "="), padding: false),
         {:ok, _} <- Base.url_decode64(String.trim_trailing(auth, "="), padding: false) do
      {:ok, %{endpoint: endpoint, p256dh: p256dh, auth: auth, origin: origin}}
    else
      _ -> :error
    end
  end

  defp parse(_subscription, _origin), do: :error

  # The table is the truth; `subs` is this process's copy of the tenant's rows.
  defp keep(state, sub) do
    row = Map.merge(sub, %{tenant: state.tenant, inserted_at: DateTime.utc_now()})

    Repo.insert_all("push_subscriptions", [row],
      on_conflict: {:replace, [:p256dh, :auth, :origin]},
      conflict_target: [:tenant, :endpoint]
    )

    put_in(state.subs[sub.endpoint], sub)
  end

  defp drop(state, endpoint) do
    Repo.delete_all(
      from(s in "push_subscriptions", where: s.tenant == ^state.tenant and s.endpoint == ^endpoint)
    )

    %{state | subs: Map.delete(state.subs, endpoint)}
  end

  defp load(t) do
    from(s in "push_subscriptions",
      where: s.tenant == ^t,
      select: %{endpoint: s.endpoint, p256dh: s.p256dh, auth: s.auth, origin: s.origin}
    )
    |> Repo.all()
    |> Map.new(&{&1.endpoint, &1})
  end
end
