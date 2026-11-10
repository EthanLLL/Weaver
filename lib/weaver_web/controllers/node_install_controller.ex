defmodule WeaverWeb.NodeInstallController do
  @moduledoc """
  What a device fetches to join its tenant (the host's): `GET
  /node/install/:code` is a shell script, meant for `curl -fsSL … | sh`, and
  `GET /node/download/:target` is the `weaver-node` binary it downloads.
  Loom's, for a tenant.

  The script is the only place a device's token is ever shown. Fetching it
  redeems the one-time code (`Weaver.Nodes.redeem/2`), which mints a fresh
  token and kills the old one: a second fetch of the same link gets nothing,
  and reinstalling a device is how its token is replaced.

  The binaries are not secret: they are built into `priv/node/` by
  `bin/deploy` (`make -C node`) and carry no credentials.
  """
  use WeaverWeb, :controller

  @targets ~w(darwin-arm64 darwin-amd64 linux-arm64 linux-amd64)

  def script(conn, %{"code" => code}) do
    case WeaverWeb.At.at(conn, Weaver.Nodes, :redeem, [code]) do
      {:ok, node, token} ->
        conn
        |> put_resp_content_type("text/x-shellscript")
        |> put_resp_header("cache-control", "no-store")
        |> send_resp(200, script(origin(conn), node.name, token))

      {:error, _} ->
        conn
        |> put_resp_content_type("text/x-shellscript")
        |> send_resp(404, """
        #!/bin/sh
        echo "weaver-node: this install link is used up or expired; make a new one in Devices" >&2
        exit 1
        """)
    end
  end

  def download(conn, %{"target" => target}) when target in @targets do
    path = Application.app_dir(:weaver, "priv/node/weaver-node-#{target}")

    if File.regular?(path) do
      conn
      |> put_resp_content_type("application/octet-stream")
      |> send_file(200, path)
    else
      send_resp(conn, 404, "weaver-node for #{target} was not built\n")
    end
  end

  def download(conn, _params), do: send_resp(conn, 404, "no such target\n")

  # The origin the device reached us on, which is the one it should keep
  # dialling. Cloudflare terminates TLS, so the scheme is in the header.
  defp origin(conn) do
    case get_req_header(conn, "x-forwarded-proto") do
      [scheme | _] ->
        "#{scheme}://#{conn.host}"

      [] ->
        default? = {conn.scheme, conn.port} in [{:http, 80}, {:https, 443}]
        "#{conn.scheme}://#{conn.host}#{if default?, do: "", else: ":#{conn.port}"}"
    end
  end

  defp script(origin, name, token) do
    """
    #!/bin/sh
    # Installs weaver-node for "#{name}" on #{origin}. The token below is this
    # device's own; the link that printed it no longer works.
    set -eu

    URL='#{origin}'
    TOKEN='#{token}'

    os=$(uname -s | tr '[:upper:]' '[:lower:]')
    case "$os" in
      darwin|linux) ;;
      *) echo "weaver-node: $os is not supported" >&2; exit 1 ;;
    esac
    case "$(uname -m)" in
      x86_64|amd64) arch=amd64 ;;
      arm64|aarch64) arch=arm64 ;;
      *) echo "weaver-node: $(uname -m) is not supported" >&2; exit 1 ;;
    esac

    bin="$HOME/.local/bin"
    mkdir -p "$bin"
    tmp="$bin/.weaver-node.$$"
    trap 'rm -f "$tmp"' EXIT
    echo "downloading weaver-node for $os-$arch"
    curl -fsSL "$URL/node/download/$os-$arch" -o "$tmp"
    chmod 755 "$tmp"
    mv "$tmp" "$bin/weaver-node"

    "$bin/weaver-node" install --url "$URL" --token "$TOKEN" --shell "${SHELL:-/bin/sh}"
    """
  end
end
