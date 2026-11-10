defmodule WeaverWeb.PushController do
  @moduledoc """
  Turning notifications on and off for one device, for the host's tenant;
  see `Weaver.Push`. Loom's API:

  - `GET /api/push` gives the VAPID public key to subscribe with (404 when
    the platform has none).
  - `POST /api/push/subscriptions` with `%{subscription:, test:}` keeps what
    `PushSubscription.toJSON()` returned. The origin notifications link back
    to is this request's host, whatever the body says.
  - `DELETE /api/push/subscriptions` with `%{endpoint:}` forgets one.
  """
  use WeaverWeb, :controller

  import WeaverWeb.At, only: [at: 4]

  alias Weaver.Push

  def show(conn, _params) do
    case Push.public_key() do
      nil -> conn |> put_status(404) |> json(%{error: "no push keys"})
      key -> json(conn, %{key: key})
    end
  end

  def create(conn, %{"subscription" => subscription} = params) do
    origin = "https://#{conn.host}"

    case at(conn, Push, :subscribe, [subscription, origin, params["test"] == true]) do
      :ok -> send_resp(conn, 204, "")
      {:error, :invalid} -> conn |> put_status(422) |> json(%{error: "invalid subscription"})
      {:error, _} -> conn |> put_status(503) |> json(%{error: "tenant unavailable"})
    end
  end

  def create(conn, _params), do: conn |> put_status(422) |> json(%{error: "invalid subscription"})

  def delete(conn, %{"endpoint" => endpoint}) when is_binary(endpoint) do
    at(conn, Push, :unsubscribe, [endpoint])
    send_resp(conn, 204, "")
  end

  def delete(conn, _params), do: conn |> put_status(422) |> json(%{error: "endpoint required"})
end
