defmodule Weaver.Cron do
  @moduledoc """
  Scheduled prompts: at each match of a cron expression (UTC,
  `Weaver.Cron.Expr`), a fixed prompt is submitted to one of the tenant's
  sessions, as if the user had typed it. Loom's `Loom.Cron`, for many
  tenants.

  ## Where it runs

  The jobs are platform data, in the `cron_jobs` table: Weaver acts on them
  while the tenant is not running at all, which is the point of a schedule.

  Every node runs one of these, and it times the jobs of the tenants whose
  VMs are on that node (`Weaver.Host.vms/0`), as a tenant's other processes
  run beside its VM. Which node a job belongs to is not stored; it follows
  the VM. Nothing here holds a tenant up: a job firing starts the tenant,
  submits, and the tenant idles away again afterwards.

  Each node keeps its jobs in memory with their next time and one timer for
  the soonest. A change is written to the table and broadcast as
  `{:cron_changed, t}` on `"cron"`; the node with that tenant's VM reads the
  tenant's jobs again. A VM appearing on a node does the same (`Weaver.Calls`).

  ## Firing

  - Off this process, at most `@concurrency` at a time: many tenants share
    a 09:00, and each may need its tenant and session started cold.
  - A minute missed while the node was down is skipped, not caught up: the
    next match is counted from boot.
  - A busy target gets the prompt the way a typed message would: steered
    into the running turn, or queued. A target that is gone records
    `last_error`.

  Jobs are made by programs in the VM, `weaver cron.add|list|delete`
  (`Weaver.Calls`), and listed with `/cron` in any session.
  """
  use GenServer

  import Ecto.Query

  require Logger

  alias Weaver.Cron.{Expr, Job}
  alias Weaver.Repo

  # Wake at least this often even with nothing due, so a clock that jumps (an
  # NTP step) is noticed within the hour.
  @max_sleep :timer.hours(1)
  @concurrency 4
  @topic "cron"

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  # ── API, from any node ──────────────────────────────────────────────────

  @doc """
  Add a job for tenant `t`: `:cron`, `:target` (a session id), `:prompt`, and
  optionally `:name`; atom or string keys. `{:ok, job}` with `next_at`, or
  `{:error, reason}`.
  """
  def add(t, attrs) do
    attrs = Map.new(attrs, fn {k, v} -> {to_string(k), v} end)
    prompt = if is_binary(attrs["prompt"]), do: String.trim(attrs["prompt"]), else: nil

    with {:ok, expr} <- parse(attrs["cron"]),
         :ok <- check_prompt(prompt),
         :ok <- check_target(t, attrs["target"]) do
      job =
        Repo.insert!(%Job{
          id: "c_" <> Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false),
          tenant: t,
          name: name(attrs["name"], prompt),
          cron: attrs["cron"] |> String.split() |> Enum.join(" "),
          target: attrs["target"],
          prompt: prompt
        })

      changed(t)
      {:ok, public(job, next_at(expr), titles(t))}
    end
  end

  @doc "Tenant `t`'s jobs, soonest first, with `next_at` and the target's title."
  def list(t) do
    titles = titles(t)

    Job
    |> where(tenant: ^t)
    |> Repo.all()
    |> Enum.map(fn job ->
      next = with {:ok, expr} <- Expr.parse(job.cron), do: next_at(expr), else: (_ -> nil)
      public(job, next, titles)
    end)
    |> Enum.sort_by(&(&1.next_at || "9999"))
  end

  @doc "Remove one of tenant `t`'s jobs. `:ok` or `{:error, :not_found}`."
  def delete(t, id) do
    case Repo.delete_all(from(j in Job, where: j.tenant == ^t and j.id == ^id)) do
      {1, _} ->
        changed(t)
        :ok

      {0, _} ->
        {:error, :not_found}
    end
  end

  @doc "Read tenant `t`'s jobs again, wherever they are timed."
  def changed(t), do: Phoenix.PubSub.broadcast(Weaver.PubSub, @topic, {:cron_changed, t})

  # ── Server ──────────────────────────────────────────────────────────────

  @impl true
  def init(nil) do
    Phoenix.PubSub.subscribe(Weaver.PubSub, @topic)
    {:ok, %{jobs: %{}, timer: nil, queue: :queue.new(), running: 0}, {:continue, :load}}
  end

  @impl true
  def handle_continue(:load, state) do
    tenants = local_tenants()
    jobs = Job |> where([j], j.tenant in ^tenants) |> Repo.all()
    Logger.info("Weaver.Cron: #{length(jobs)} jobs for #{length(tenants)} tenants here")
    {:noreply, arm(%{state | jobs: Map.new(jobs, &{&1.id, schedule(&1)})})}
  end

  @impl true
  def handle_info({:cron_changed, t}, state) do
    jobs = Map.reject(state.jobs, fn {_, job} -> job.tenant == t end)

    jobs =
      if t in local_tenants(),
        do: Job |> where(tenant: ^t) |> Repo.all() |> Enum.into(jobs, &{&1.id, schedule(&1)}),
        else: jobs

    {:noreply, arm(%{state | jobs: jobs})}
  end

  def handle_info(:tick, state) do
    now = DateTime.utc_now()

    due =
      for {_, %{next_at: %DateTime{} = at} = job} <- state.jobs,
          DateTime.compare(at, now) != :gt,
          do: job

    state =
      Enum.reduce(due, state, fn job, state ->
        Repo.update_all(from(j in Job, where: j.id == ^job.id), set: [last_run_at: now])
        put_in(state.jobs[job.id], schedule(job, now))
      end)

    queue = Enum.reduce(due, state.queue, &:queue.in/2)
    {:noreply, %{state | queue: queue, timer: nil} |> start_due() |> arm()}
  end

  def handle_info({:delivered, id, result}, state) do
    error = if result == :ok, do: nil, else: inspect(result)
    if error, do: Logger.warning("Weaver.Cron #{id}: #{error}")
    Repo.update_all(from(j in Job, where: j.id == ^id), set: [last_error: error])
    {:noreply, start_due(%{state | running: state.running - 1})}
  end

  # ── Firing ──────────────────────────────────────────────────────────────

  defp start_due(%{running: running} = state) when running >= @concurrency, do: state

  defp start_due(state) do
    case :queue.out(state.queue) do
      {{:value, job}, queue} ->
        server = self()
        Task.start(fn -> send(server, {:delivered, job.id, deliver(job)}) end)
        start_due(%{state | queue: queue, running: state.running + 1})

      {:empty, _} ->
        state
    end
  end

  # Starts the tenant if it is not running, and the session with it.
  defp deliver(job) do
    case Weaver.Tenant.at(job.tenant, Weaver.Agent, :submit, [
           job.tenant,
           job.target,
           job.prompt,
           [origin: "cron"]
         ]) do
      {:ok, _} -> :ok
      other -> other
    end
  catch
    kind, reason -> {kind, reason}
  end

  # ── Jobs ────────────────────────────────────────────────────────────────

  defp local_tenants, do: Enum.map(Weaver.Host.vms(), & &1.name)

  defp parse(cron) when is_binary(cron) do
    with {:ok, expr} <- Expr.parse(cron) do
      if next_at(expr), do: {:ok, expr}, else: {:error, "this cron expression never matches"}
    end
  end

  defp parse(_), do: {:error, "a cron expression is required"}

  defp check_prompt(prompt) when is_binary(prompt) and prompt != "", do: :ok
  defp check_prompt(_), do: {:error, "a prompt is required"}

  # Only a session that exists: a typo would otherwise sit there firing into
  # nothing. One deleted later shows up as `last_error` instead.
  defp check_target(t, target) when is_binary(target) do
    if Map.has_key?(titles(t), target),
      do: :ok,
      else: {:error, "no session #{inspect(target)}"}
  end

  defp check_target(_t, _), do: {:error, "a target session id is required"}

  defp titles(t) do
    case Weaver.Tenant.sessions(t) do
      sessions when is_list(sessions) -> Map.new(sessions, &{&1.id, &1.title})
      _ -> %{}
    end
  end

  defp name(name, prompt) when name in [nil, ""],
    do: prompt |> String.split("\n") |> hd() |> String.slice(0, 40)

  defp name(name, _prompt), do: to_string(name)

  defp next_at(expr, now \\ DateTime.utc_now()) do
    case Expr.next(expr, now) do
      {:ok, at} -> at
      :none -> nil
    end
  end

  # `next_at` is derived, never stored: counted from now at boot, which is
  # what skips the minutes a node was down for.
  defp schedule(job, now \\ DateTime.utc_now()) do
    next = with {:ok, expr} <- Expr.parse(job.cron), do: next_at(expr, now), else: (_ -> nil)
    Map.put(job, :next_at, next)
  end

  defp arm(state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    soonest =
      state.jobs
      |> Map.values()
      |> Enum.map(& &1.next_at)
      |> Enum.reject(&is_nil/1)
      |> Enum.min(DateTime, fn -> nil end)

    sleep =
      case soonest do
        nil -> @max_sleep
        at -> at |> DateTime.diff(DateTime.utc_now(), :millisecond) |> max(0) |> min(@max_sleep)
      end

    %{state | timer: Process.send_after(self(), :tick, sleep)}
  end

  defp public(job, next_at, titles) do
    %{
      id: job.id,
      name: job.name,
      cron: job.cron,
      target: job.target,
      target_title: titles[job.target],
      prompt: job.prompt,
      next_at: iso(next_at),
      last_run_at: iso(job.last_run_at),
      last_error: job.last_error
    }
  end

  defp iso(nil), do: nil
  defp iso(at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
