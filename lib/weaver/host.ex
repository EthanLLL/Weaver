defmodule Weaver.Host do
  @moduledoc """
  The tenant VMs on this host, one directory each under `/opt/weaver/vms`,
  run by `/opt/weaver/vm.sh` as the systemd unit `weaver-vm@<name>`.

  A VM is made at sign-up (`create/1`) and booted when its tenant is first
  needed (`boot/1`, from `Weaver.Tenant`). Made is all it takes to exist: its
  directory is what `Weaver.Calls` listens for and `Weaver.Cron` times, so a
  tenant who has never logged in is still a tenant, and costs only its disk.

  This process makes both one at a time per VM: two sign-ups must not take
  the same network, and everything that wants a stopped VM at once waits on
  the one boot.
  """
  use GenServer

  require Logger

  @dir "/opt/weaver/vms"
  @image "/opt/weaver/image.ext4"
  # Taps fc1..fc250, guest 172.16.<n>.2 (`vm.sh`).
  @nets 1..250
  @boot_timeout :timer.seconds(60)

  def dir, do: @dir

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

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

  @doc """
  Make a VM here for a new tenant: its disk a copy of the image, a network of
  its own. Not booted. `:ok` or `{:error, reason}`.
  """
  def create(name), do: GenServer.call(__MODULE__, {:create, name}, :timer.minutes(2))

  @doc "Boot a VM that exists here, if it is not running, and wait for its guest to answer."
  def boot(name), do: GenServer.call(__MODULE__, {:boot, name}, @boot_timeout + 5_000)

  @doc "Boot it regardless of whether its guest answers (the operator's `Weaver.start/1`)."
  def start(name) do
    with {:ok, n} <- File.read(Path.join([@dir, name, "net"])),
         :ok <- Weaver.Calls.ensure(name) do
      run(["bash", "/opt/weaver/vm.sh", name, String.trim(n)])
    end
  end

  def stop(name), do: run(["systemctl", "stop", unit(name)])

  @doc "Stop a VM and delete it, disk and all. For `Weaver.Accounts.delete/1`."
  def destroy(name), do: GenServer.call(__MODULE__, {:destroy, name}, :timer.minutes(1))

  # ── Server ──────────────────────────────────────────────────────────────

  @impl true
  def init(nil), do: {:ok, %{booting: %{}}}

  @impl true
  def handle_call({:create, name}, _from, state), do: {:reply, make(name), state}

  def handle_call({:destroy, name}, _from, state) do
    dir = Path.join(@dir, name)

    reply =
      with true <- File.exists?(dir) || {:error, :no_such_vm},
           :ok <- if(status(name) == "active", do: stop(name), else: :ok) do
        Weaver.Calls.forget(name)
        File.rm_rf!(dir)
        :ok
      end

    {:reply, reply, state}
  end

  def handle_call({:boot, name}, from, state) do
    cond do
      Map.has_key?(state.booting, name) ->
        {:noreply, update_in(state.booting[name], &[from | &1])}

      ready?(name) ->
        {:reply, :ok, state}

      true ->
        server = self()

        Task.start(fn ->
          started = System.monotonic_time(:millisecond)
          result = with :ok <- start_unless_running(name), do: await_guest(name, started)
          ms = System.monotonic_time(:millisecond) - started
          Logger.info("Weaver.Host: booted #{name} in #{ms} ms: #{inspect(result)}")
          send(server, {:booted, name, result})
        end)

        {:noreply, put_in(state.booting[name], [from])}
    end
  end

  @impl true
  def handle_info({:booted, name, result}, state) do
    {waiting, booting} = Map.pop(state.booting, name)
    for from <- waiting, do: GenServer.reply(from, result)
    {:noreply, %{state | booting: booting}}
  end

  # ── Making ──────────────────────────────────────────────────────────────

  defp make(name) do
    dir = Path.join(@dir, name)

    cond do
      File.exists?(dir) ->
        {:error, :exists}

      not File.exists?(@image) ->
        {:error, :no_image}

      true ->
        with {:ok, n} <- free_net() do
          File.mkdir_p!(dir)

          # Sparse: the image is 4 GB, about a quarter of it used.
          case System.cmd("cp", ["--sparse=always", @image, Path.join(dir, "rootfs.ext4")],
                 stderr_to_stdout: true
               ) do
            {_, 0} ->
              File.write!(Path.join(dir, "net"), "#{n}\n")
              Weaver.Calls.ensure(name)

            {out, _} ->
              File.rm_rf!(dir)
              {:error, String.trim(out)}
          end
        end
    end
  end

  defp free_net do
    taken =
      for %{name: vm} <- vms(),
          {:ok, n} <- [File.read(Path.join([@dir, vm, "net"]))],
          {n, _} <- [Integer.parse(n)],
          do: n

    case Enum.find(@nets, &(&1 not in taken)) do
      nil -> {:error, :full}
      n -> {:ok, n}
    end
  end

  # ── Booting ─────────────────────────────────────────────────────────────

  defp start_unless_running(name) do
    if status(name) == "active", do: :ok, else: start(name)
  end

  defp ready?(name) do
    case Weaver.Guest.connect(name) do
      {:ok, sock} ->
        :gen_tcp.close(sock)
        true

      _ ->
        false
    end
  end

  # The guest listens once its systemd unit is up, a few seconds in.
  defp await_guest(name, started) do
    cond do
      ready?(name) ->
        :ok

      System.monotonic_time(:millisecond) - started > @boot_timeout ->
        {:error, :boot_timeout}

      true ->
        Process.sleep(200)
        await_guest(name, started)
    end
  end

  defp unit(name), do: "weaver-vm@#{name}"

  defp run(argv) do
    case System.cmd("sudo", argv, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, String.trim(out)}
    end
  end
end
