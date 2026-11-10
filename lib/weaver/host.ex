defmodule Weaver.Host do
  @moduledoc """
  The tenant VMs on this host, one directory each under `/opt/weaver/vms`,
  run by `/opt/weaver/vm.sh` as the systemd unit `weaver-vm@<name>`.
  """

  @dir "/opt/weaver/vms"

  def dir, do: @dir

  @doc "This host's VMs: `%{name, status}`, status as systemd says it."
  def vms do
    case File.ls(@dir) do
      {:ok, names} -> for name <- Enum.sort(names), do: %{name: name, status: status(name)}
      {:error, _} -> []
    end
  end

  def status(name) do
    {out, _} = System.cmd("systemctl", ["is-active", unit(name)])
    String.trim(out)
  end

  @doc "Boot a VM that exists here, on the network it was made with."
  def start(name) do
    with {:ok, n} <- File.read(Path.join([@dir, name, "net"])) do
      run(["bash", "/opt/weaver/vm.sh", name, String.trim(n)])
    end
  end

  def stop(name), do: run(["systemctl", "stop", unit(name)])

  defp unit(name), do: "weaver-vm@#{name}"

  defp run(argv) do
    case System.cmd("sudo", argv, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, String.trim(out)}
    end
  end
end
