defmodule Weaver do
  @moduledoc """
  The control plane: every tenant VM on every connected host, as one list.

  There is no registry. Each host knows its own VMs (`Weaver.Host`); asking
  the cluster is asking every node.
  """

  @doc "All tenants: `%{name, node, status}`."
  def tenants do
    nodes = [node() | Node.list()]

    nodes
    |> :erpc.multicall(Weaver.Host, :vms, [], 5000)
    |> Enum.zip(nodes)
    |> Enum.flat_map(fn
      {{:ok, vms}, node} -> Enum.map(vms, &Map.put(&1, :node, node))
      {_, _} -> []
    end)
  end

  @doc "The node a tenant's VM is on."
  def where(tenant) do
    case Enum.find(tenants(), &(&1.name == tenant)) do
      nil -> {:error, :no_such_tenant}
      t -> {:ok, t.node}
    end
  end

  def start(tenant), do: on(tenant, :start)
  def stop(tenant), do: on(tenant, :stop)

  defp on(tenant, fun) do
    with {:ok, node} <- where(tenant), do: :erpc.call(node, Weaver.Host, fun, [tenant], 60_000)
  end

  @doc "A file operation in a tenant's VM (see `Weaver.Guest.file/4`)."
  def file(tenant, op, path, data \\ nil) do
    with {:ok, node} <- where(tenant),
         do: :erpc.call(node, Weaver.Guest, :file, [tenant, op, path, data], 60_000)
  end

  @doc """
  Run a shell command in a tenant's VM, wherever it is, and wait for it:
  `{:ok, %{stdout, stderr, status}}`.
  """
  def run(tenant, command, timeout \\ 60_000) do
    with {:ok, node} <- where(tenant),
         {:ok, pid} <-
           :erpc.call(node, Weaver.Exec, :start, [tenant, ["sh", "-c", command], self()]) do
      Weaver.Exec.close(pid)
      collect(pid, %{stdout: [], stderr: []}, timeout)
    end
  end

  defp collect(pid, acc, timeout) do
    receive do
      {^pid, {:data, stream, data}} ->
        collect(pid, Map.update!(acc, stream, &[&1 | data]), timeout)

      {^pid, {:exit_status, code}} ->
        {:ok,
         %{
           stdout: IO.iodata_to_binary(acc.stdout),
           stderr: IO.iodata_to_binary(acc.stderr),
           status: code
         }}

      {^pid, {:error, why}} ->
        {:error, why}
    after
      timeout -> {:error, :timeout}
    end
  end
end
