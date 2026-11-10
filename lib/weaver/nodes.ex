defmodule Weaver.Nodes do
  @moduledoc """
  A tenant's own machines (a Mac, a WSL box) that their agents can run
  commands on: Loom's `Loom.Nodes`, for many tenants.

  Each runs `weaver-node daemon` (`node/`), which dials the tenant's host,
  `wss://<tenant>.luozhen.cloud/node`, and joins `WeaverWeb.NodeChannel`. An
  agent in the VM reaches it with `weaver node …` (`guest/node.go`), a call
  that `Weaver.Calls.Node` relays to the device's channel.

  ## What is where

  - **Registered devices** are platform data, in the `devices` table: names,
    what each said about itself, and the SHA-256 of its token and of its
    one-time install code, never either itself.
  - **Who is online** is the channels themselves: each is in the `:pg` group
    `group(t, id)`, on whichever node Cloudflare sent it to. Nothing here is
    a process, so a device connecting starts nothing, and an always-connected
    daemon does not hold its tenant up.

  As in Loom, redeeming an install code mints the device's token and kills
  the previous one, and a connection made with it.

  ## Broadcasts

  On the tenant's lobby topic, for the sidebar: `{:node_summary, summary}`
  and `{:node_removed, id}`. On `nodes_topic/1`, `{:node_online, id}`, for a
  request waiting on a device that is reconnecting.
  """

  import Ecto.Query

  alias Weaver.Repo
  alias Weaver.Nodes.Device

  @pg Weaver.PG
  @install_ttl_s 3600
  @name_format ~r/^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$/

  def nodes_topic(t), do: "tenant:#{t}:nodes"

  @doc "The `:pg` group a device's channel is in while it is connected."
  def group(t, id), do: {:device, t, id}

  @doc "Every device of tenant `t`, oldest first, with `online`."
  def list(t) do
    Device
    |> where(tenant: ^t)
    |> order_by(:inserted_at)
    |> Repo.all()
    |> Enum.map(&summary/1)
  end

  @doc "Register a device. `{:ok, summary, install_code}` or `{:error, reason}`."
  def create(t, name) do
    with {:ok, name} <- check_name(name) do
      code = random(16)

      %Device{
        id: "n_" <> random(6),
        tenant: t,
        name: name,
        install_code_hash: hash(code),
        install_code_expires_at: expiry()
      }
      |> Device.changeset()
      |> Repo.insert()
      |> case do
        {:ok, device} ->
          announce(device)
          {:ok, summary(device), code}

        {:error, _} ->
          {:error, "there is already a device called #{name}"}
      end
    end
  end

  def rename(t, id, name) do
    with {:ok, name} <- check_name(name),
         {:ok, device} <- fetch(t, id) do
      case device |> Ecto.Changeset.change(name: name) |> Device.changeset() |> Repo.update() do
        {:ok, device} ->
          announce(device)
          {:ok, summary(device)}

        {:error, _} ->
          {:error, "there is already a device called #{name}"}
      end
    end
  end

  @doc "Forget a device: its token stops working and a live connection is dropped."
  def delete(t, id) do
    with {:ok, device} <- fetch(t, id) do
      Repo.delete!(device)
      drop_connections(t, id)
      Phoenix.PubSub.broadcast(Weaver.PubSub, Weaver.Tenant.lobby_topic(t), {:node_removed, id})
      :ok
    end
  end

  @doc "A fresh one-time install code for a registered device."
  def install_code(t, id) do
    with {:ok, device} <- fetch(t, id) do
      code = random(16)

      device
      |> Ecto.Changeset.change(install_code_hash: hash(code), install_code_expires_at: expiry())
      |> Repo.update!()

      {:ok, code}
    end
  end

  @doc """
  Trade an install code for the device's new token: `{:ok, summary, token}`.
  The code works once; the previous token, if any, is dead from here on.
  """
  def redeem(t, code) when is_binary(code) do
    now = DateTime.utc_now()

    with %Device{} = device <- Repo.get_by(Device, tenant: t, install_code_hash: hash(code)),
         :gt <- DateTime.compare(device.install_code_expires_at, now) do
      token = "wn_" <> random(32)

      device =
        device
        |> Ecto.Changeset.change(
          token_hash: hash(token),
          install_code_hash: nil,
          install_code_expires_at: nil
        )
        |> Repo.update!()

      # The old token is dead; so is a connection made with it.
      drop_connections(t, device.id)
      {:ok, summary(device), token}
    else
      _ -> {:error, :invalid_code}
    end
  end

  def redeem(_t, _code), do: {:error, :invalid_code}

  @doc "Tenant `t`'s device a token belongs to: `{:ok, id}` or `:error`."
  def authenticate(t, token) when is_binary(token) do
    case Repo.get_by(Device, tenant: t, token_hash: hash(token)) do
      %Device{id: id} -> {:ok, id}
      nil -> :error
    end
  end

  def authenticate(_t, _token), do: :error

  @doc """
  A device's channel `pid` has joined, with what the device says about
  itself. A previous connection for the same device is told to stop; the
  channel joins the device's group once this returns.
  """
  def connected(t, id, pid, info) do
    with {:ok, device} <- fetch(t, id) do
      drop_connections(t, id, pid)

      device =
        device
        |> Ecto.Changeset.change(
          os: info["os"],
          arch: info["arch"],
          hostname: info["hostname"],
          version: info["version"],
          last_seen_at: DateTime.utc_now()
        )
        |> Repo.update!()

      Phoenix.PubSub.broadcast(Weaver.PubSub, nodes_topic(t), {:node_online, id})
      {:ok, device}
    end
  end

  @doc "A device's channel is going away: when it was last seen, and say so."
  def disconnected(t, id) do
    case fetch(t, id) do
      {:ok, device} ->
        device
        |> Ecto.Changeset.change(last_seen_at: DateTime.utc_now())
        |> Repo.update!()
        |> announce()

      _ ->
        :ok
    end
  end

  @doc "Tell the sidebar about a device as it is now (online is the `:pg` group)."
  def announce(%Device{} = device) do
    Phoenix.PubSub.broadcast(
      Weaver.PubSub,
      Weaver.Tenant.lobby_topic(device.tenant),
      {:node_summary, summary(device)}
    )
  end

  def announce(t, id) do
    with {:ok, device} <- fetch(t, id), do: announce(device)
  end

  @doc "The channel for a device, by name: `{:ok, pid}`, `{:offline, summary}` or `:unknown`."
  def lookup(t, name) when is_binary(name) do
    device =
      Device
      |> where([d], d.tenant == ^t and fragment("lower(?)", d.name) == ^String.downcase(name))
      |> Repo.one()

    case device && :pg.get_members(@pg, group(t, device.id)) do
      nil -> :unknown
      [pid | _] -> {:ok, pid}
      [] -> {:offline, summary(device)}
    end
  end

  @doc """
  Like `lookup/2`, but an offline device gets `timeout` ms to come back: a
  Mac just woken from sleep is usually seconds from reconnecting.
  """
  def await(t, name, timeout) do
    Phoenix.PubSub.subscribe(Weaver.PubSub, nodes_topic(t))

    try do
      wait(t, name, System.monotonic_time(:millisecond) + timeout)
    after
      Phoenix.PubSub.unsubscribe(Weaver.PubSub, nodes_topic(t))
    end
  end

  defp wait(t, name, deadline) do
    case lookup(t, name) do
      {:offline, _summary} = offline ->
        remaining = deadline - System.monotonic_time(:millisecond)

        receive do
          {:node_online, _id} -> wait(t, name, deadline)
        after
          max(remaining, 0) -> offline
        end

      other ->
        other
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────────────

  defp summary(%Device{} = d) do
    %{
      id: d.id,
      name: d.name,
      os: d.os,
      arch: d.arch,
      hostname: d.hostname,
      version: d.version,
      created_at: iso(d.inserted_at),
      last_seen_at: iso(d.last_seen_at),
      online: :pg.get_members(@pg, group(d.tenant, d.id)) != []
    }
  end

  defp iso(nil), do: nil
  defp iso(at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  # Stops the device's channels (but `keep`). The device takes a channel that
  # goes away as a dropped connection and redials, and a dead token is
  # refused at connect.
  defp drop_connections(t, id, keep \\ nil) do
    for pid <- :pg.get_members(@pg, group(t, id)), pid != keep, do: send(pid, :node_replaced)
    :ok
  end

  defp fetch(t, id) when is_binary(id) do
    case Repo.get_by(Device, tenant: t, id: id) do
      %Device{} = device -> {:ok, device}
      nil -> {:error, :not_found}
    end
  end

  defp fetch(_t, _id), do: {:error, :not_found}

  defp check_name(name) when is_binary(name) do
    name = String.trim(name)

    if Regex.match?(@name_format, name),
      do: {:ok, name},
      else: {:error, "a name is 1–32 letters, digits, dots, dashes or underscores"}
  end

  defp check_name(_name), do: {:error, "a name is required"}

  defp expiry, do: DateTime.add(DateTime.utc_now(), @install_ttl_s)

  defp hash(secret), do: :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)

  defp random(bytes), do: Base.url_encode64(:crypto.strong_rand_bytes(bytes), padding: false)
end
