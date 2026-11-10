defmodule Weaver.Accounts do
  @moduledoc """
  Tenants as people who sign up and log in: a name, which is their host
  (`<name>.luozhen.cloud`), and a password, in the `tenants` table.

  ## Signing up

  Takes a one-time invite (`invite/1`, from an operator): a sign-up is a VM
  on our hosts with the internet behind it. It makes the VM, a copy of the
  image (`Weaver.Host.create/1`), on the host with the fewest, and does not
  boot it; the first login does. The row, the invite and the VM go together:
  a VM that could not be made leaves no account and the invite unused.

  ## Passwords

  PBKDF2-SHA256 from `:crypto`, salted, `@iterations` rounds. A login for a
  name that does not exist costs the same as a wrong password.
  """

  import Ecto.Query

  require Logger

  alias Weaver.Repo

  @iterations 600_000
  @name_format ~r/\A[a-z][a-z0-9-]{1,30}[a-z0-9]\z/
  # Hosts that are, or should stay, something other than a tenant: the
  # platform's own, and the other records under the domain.
  @reserved ~w(weaver www api admin app apps auth login signup register static assets
               cdn mail status docs help support node loom share moment ma root test)

  @doc """
  Sign up: `{:ok, name}` once the VM is made, or `{:error, message}`, worded
  for the person signing up.
  """
  def signup(name, password, invite) do
    name = name |> to_string() |> String.trim() |> String.downcase()

    with :ok <- check_name(name),
         :ok <- check_password(password),
         :ok <- if(Weaver.Tenant.exists?(name), do: {:error, taken(name)}, else: :ok) do
      now = DateTime.utc_now()

      Repo.transaction(
        fn ->
          case Repo.update_all(
                 from(i in "invites",
                   where: i.code_hash == ^hash(to_string(invite)) and is_nil(i.used_by)
                 ),
                 set: [used_by: name, used_at: now]
               ) do
            {1, _} -> :ok
            {0, _} -> Repo.rollback("that invite code is not valid, or has been used")
          end

          case Repo.insert_all(
                 "tenants",
                 [%{name: name, password_hash: hash_password(password), inserted_at: now}],
                 on_conflict: :nothing
               ) do
            {1, _} -> :ok
            {0, _} -> Repo.rollback(taken(name))
          end

          case place(name) do
            :ok ->
              name

            {:error, reason} ->
              Logger.error("Weaver.Accounts: no VM for #{name}: #{inspect(reason)}")
              Repo.rollback("could not make your machine; try again later")
          end
        end,
        timeout: :timer.minutes(3)
      )
    end
  end

  @doc "Whether `password` is `name`'s: `:ok` or `:error`."
  def authenticate(name, password) when is_binary(name) and is_binary(password) do
    stored = Repo.one(from(t in "tenants", where: t.name == ^name, select: t.password_hash))

    # Hash anyway when there is no such tenant, so the answer takes as long.
    if verify_password(password, stored || hash_password("")) and stored != nil,
      do: :ok,
      else: :error
  end

  def authenticate(_, _), do: :error

  @doc "A new one-time invite code, for an operator to hand out (`bin/ctl`)."
  def invite(note \\ nil) do
    code = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    Repo.insert_all("invites", [
      %{code_hash: hash(code), note: note, inserted_at: DateTime.utc_now()}
    ])

    code
  end

  @doc "Set a tenant's password, for an operator; also gives a tenant made by hand an account."
  def set_password(name, password) do
    with :ok <- check_password(password) do
      Repo.insert_all(
        "tenants",
        [%{name: name, password_hash: hash_password(password), inserted_at: DateTime.utc_now()}],
        on_conflict: {:replace, [:password_hash]},
        conflict_target: :name
      )

      :ok
    end
  end

  @doc """
  Delete a tenant, for an operator: their VM with everything in it, and
  every row of theirs. Irreversible.
  """
  def delete(name) do
    with {:ok, node} <- Weaver.Tenant.vm_node(name),
         :ok <- :erpc.call(node, __MODULE__, :delete_here, [name], :timer.minutes(1)) do
      for table <- ~w(tenants), do: Repo.delete_all(from(r in table, where: r.name == ^name))

      for table <- ~w(devices push_subscriptions cron_jobs),
          do: Repo.delete_all(from(r in table, where: r.tenant == ^name))

      Weaver.Cron.changed(name)
      :ok
    end
  end

  @doc false
  def delete_here(name) do
    case GenServer.whereis(Weaver.Tenant.via(name, :tree)) do
      nil -> :ok
      tree -> DynamicSupervisor.terminate_child(Weaver.Tenants, tree)
    end

    Weaver.Host.destroy(name)
  end

  # ── Placement ───────────────────────────────────────────────────────────

  # The host with the fewest VMs. Hosts are the `weaver@` nodes; an operator's
  # `bin/ctl` connects as another name and has none.
  defp place(name) do
    nodes = Enum.filter([node() | Node.list()], &String.starts_with?(to_string(&1), "weaver@"))

    counts =
      nodes
      |> :erpc.multicall(Weaver.Host, :vms, [], 5_000)
      |> Enum.zip(nodes)
      |> Enum.flat_map(fn
        {{:ok, vms}, node} -> [{length(vms), node}]
        _ -> []
      end)

    case Enum.min(counts, fn -> nil end) do
      nil -> {:error, :no_hosts}
      {_, node} -> :erpc.call(node, Weaver.Host, :create, [name], :timer.minutes(2))
    end
  end

  # ── Checks ──────────────────────────────────────────────────────────────

  defp check_name(name) do
    cond do
      not Regex.match?(@name_format, name) ->
        {:error,
         "a name is 3–32 lowercase letters, digits or dashes, starting with a letter and not ending with a dash"}

      name in @reserved ->
        {:error, taken(name)}

      true ->
        :ok
    end
  end

  defp check_password(p) when is_binary(p) and byte_size(p) >= 8 and byte_size(p) <= 256, do: :ok
  defp check_password(_), do: {:error, "a password is at least 8 characters"}

  defp taken(name), do: "#{name} is taken"

  # ── Hashing ─────────────────────────────────────────────────────────────

  defp hash_password(password) do
    salt = :crypto.strong_rand_bytes(16)

    Enum.join(
      [
        "pbkdf2-sha256",
        @iterations,
        Base.encode64(salt),
        Base.encode64(pbkdf2(password, salt, @iterations))
      ],
      "$"
    )
  end

  defp verify_password(password, stored) do
    with ["pbkdf2-sha256", iterations, salt, hash] <- String.split(stored, "$"),
         {iterations, ""} <- Integer.parse(iterations),
         {:ok, salt} <- Base.decode64(salt),
         {:ok, hash} <- Base.decode64(hash) do
      Plug.Crypto.secure_compare(pbkdf2(password, salt, iterations), hash)
    else
      _ -> false
    end
  end

  defp pbkdf2(password, salt, iterations),
    do: :crypto.pbkdf2_hmac(:sha256, password, salt, iterations, 32)

  defp hash(secret), do: :crypto.hash(:sha256, secret) |> Base.encode16(case: :lower)
end
