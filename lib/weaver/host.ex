defmodule Weaver.Host do
  @moduledoc """
  The tenant VMs on this host, one directory each under `/opt/weaver/vms`,
  run by `/opt/weaver/vm.sh` as the systemd unit `weaver-vm@<name>`.

  A VM is made at sign-up (`create/1`) and booted when its tenant is first
  needed (`boot/1`, from `Weaver.Tenant`). Made is all it takes to exist: its
  directory is what `Weaver.Calls` listens for and `Weaver.Cron` times, so a
  tenant who has never logged in is still a tenant, and costs only its disk.

  A VM whose tenant has gone idle is shut down (`idle/1`, from
  `Weaver.Tenant`): memory is what limits how many fit on a host, and a boot
  is a couple of seconds. Shut down, not killed: the guest is sent
  Ctrl-Alt-Del and goes down as on a reboot, its disks synced, and
  Firecracker exits (`reboot=k`).

  This process orders all of it, one thing at a time per VM: two sign-ups
  must not take the same network, everything that wants a stopped VM at once
  waits on the one boot, and a boot asked for while the VM is going down
  waits for it to be down. A VM wanted again within `@reuse_ms` of a boot is
  not shut down: the tenant stopping and starting again cross here.
  """
  use GenServer

  require Logger

  @dir "/opt/weaver/vms"
  @image "/opt/weaver/image.ext4"
  # Taps fc1..fc250, guest 172.16.<n>.2 (`vm.sh`).
  @nets 1..250
  @boot_timeout :timer.seconds(60)
  @shutdown_timeout :timer.seconds(30)
  @reuse_ms :timer.seconds(30)

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

  @doc "Shut a VM down cleanly, killing it if it does not go within `@shutdown_timeout`."
  def stop(name), do: shutdown(name)

  @doc "The tenant `name` has stopped: shut its VM down, unless it is wanted again."
  def idle(name), do: GenServer.cast(__MODULE__, {:idle, name})

  @doc "Stop a VM and delete it, disk and all. For `Weaver.Accounts.delete/1`."
  def destroy(name), do: GenServer.call(__MODULE__, {:destroy, name}, :timer.minutes(1))

  # ── Server ──────────────────────────────────────────────────────────────

  @impl true
  def init(nil), do: {:ok, %{booting: %{}, stopping: %{}, used: %{}}}

  @impl true
  def handle_call({:create, name}, _from, state), do: {:reply, make(name), state}

  def handle_call({:destroy, name}, _from, state) do
    dir = Path.join(@dir, name)

    reply =
      with true <- File.exists?(dir) || {:error, :no_such_vm},
           :ok <- if(status(name) == "active", do: kill(name), else: :ok) do
        Weaver.Calls.forget(name)
        File.rm_rf!(dir)
        :ok
      end

    {:reply, reply, state}
  end

  def handle_call({:boot, name}, from, state) do
    state = put_in(state.used[name], now())

    cond do
      Map.has_key?(state.booting, name) ->
        {:noreply, update_in(state.booting[name], &[from | &1])}

      Map.has_key?(state.stopping, name) ->
        {:noreply, update_in(state.stopping[name], &[from | &1])}

      ready?(name) ->
        {:reply, :ok, state}

      true ->
        {:noreply, start_boot(state, name, [from])}
    end
  end

  @impl true
  def handle_cast({:idle, name}, state) do
    wanted =
      Map.has_key?(state.booting, name) or Map.has_key?(state.stopping, name) or
        now() - Map.get(state.used, name, 0) < @reuse_ms or
        Registry.lookup(Weaver.Local, {:tree, name}) != []

    if wanted or status(name) != "active" do
      {:noreply, state}
    else
      server = self()
      Task.start(fn -> send(server, {:stopped, name, shutdown(name)}) end)
      {:noreply, put_in(state.stopping[name], [])}
    end
  end

  @impl true
  def handle_info({:booted, name, result}, state) do
    {waiting, booting} = Map.pop(state.booting, name)
    for from <- waiting, do: GenServer.reply(from, result)
    {:noreply, %{state | booting: booting}}
  end

  def handle_info({:stopped, name, result}, state) do
    Logger.info("Weaver.Host: shut #{name} down: #{inspect(result)}")
    {waiting, stopping} = Map.pop(state.stopping, name)
    state = %{state | stopping: stopping}
    # Asked for while it was going down.
    {:noreply, if(waiting == [], do: state, else: start_boot(state, name, waiting))}
  end

  defp start_boot(state, name, waiting) do
    server = self()

    Task.start(fn ->
      started = now()
      result = with :ok <- start_unless_running(name), do: await_guest(name, started)
      Logger.info("Weaver.Host: booted #{name} in #{now() - started} ms: #{inspect(result)}")
      send(server, {:booted, name, result})
    end)

    put_in(state.booting[name], waiting)
  end

  defp now, do: System.monotonic_time(:millisecond)

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

      now() - started > @boot_timeout ->
        {:error, :boot_timeout}

      true ->
        Process.sleep(200)
        await_guest(name, started)
    end
  end

  # ── Shutting down ───────────────────────────────────────────────────────

  defp shutdown(name) do
    if status(name) == "active" do
      ctrl_alt_del(name)
      if await_down(name, now()) == :ok, do: :ok, else: kill(name)
    else
      :ok
    end
  end

  # Firecracker's API, over its socket beside the VM's.
  defp ctrl_alt_del(name) do
    body = ~s({"action_type":"SendCtrlAltDel"})

    with {:ok, sock} <-
           :gen_tcp.connect({:local, Path.join([@dir, name, "api.sock"])}, 0, [
             :binary,
             active: false
           ]) do
      :gen_tcp.send(
        sock,
        "PUT /actions HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n" <>
          "Content-Length: #{byte_size(body)}\r\n\r\n" <> body
      )

      :gen_tcp.recv(sock, 0, 5_000)
      :gen_tcp.close(sock)
    end
  end

  defp await_down(name, started) do
    cond do
      status(name) != "active" ->
        :ok

      now() - started > @shutdown_timeout ->
        Logger.warning("Weaver.Host: #{name} did not shut down, killing it")
        :timeout

      true ->
        Process.sleep(200)
        await_down(name, started)
    end
  end

  defp kill(name), do: run(["systemctl", "stop", unit(name)])

  defp unit(name), do: "weaver-vm@#{name}"

  defp run(argv) do
    case System.cmd("sudo", argv, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {out, _} -> {:error, String.trim(out)}
    end
  end
end
