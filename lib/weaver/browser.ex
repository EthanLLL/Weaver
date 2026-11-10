defmodule Weaver.Browser do
  @moduledoc """
  A tenant's browser: a Chrome in their VM (`host/vm/weaver-browser`), that
  agents drive over CDP on the VM's `127.0.0.1:9222` and the user takes over
  through VNC on its `127.0.0.1:5900`, reached over `Weaver.Tunnel`
  (`WeaverWeb.VncSocket`). Its profile, and with it every login, is the
  tenant's, in their VM.

  Not running until something asks: the user opening the Browser view, or an
  agent, with `sudo systemctl start weaver-browser`. Once up it stays up
  until the VM stops. The first start installs Chrome, about a minute.
  """

  @vnc 5900

  def vnc_port, do: @vnc

  @doc "Ask the VM to start the browser, without waiting for it to be up."
  def start(t) do
    case Weaver.Exec.run(t, ~w(systemctl start --no-block weaver-browser), [], 10_000) do
      {:ok, %{status: 0}} -> :ok
      {:ok, %{stderr: why}} -> {:error, String.trim(why)}
      {:error, _} = error -> error
    end
  end
end
