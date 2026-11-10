defmodule Weaver.FS do
  @moduledoc """
  A tenant's files, which live in their VM: the few `File` functions the
  agent code needs, over the guest's vsock. Called on the node that has the
  VM, which is where a tenant's processes run (`Weaver.Tenant`).

  Everything made here belongs to the VM's user, `tenant`, so the agent and
  the shell in the VM can use it. Times are Unix milliseconds.
  """

  alias Weaver.Guest

  @user "tenant"

  @doc "The tenant's home in the VM."
  def home, do: "/home/#{@user}"

  def user, do: @user

  def read(t, path), do: Guest.file(t, "read", path)

  def write(t, path, data), do: Guest.file(t, "write", path, data: data, user: @user)

  @doc "Like `write/3`, raising on failure."
  def write!(t, path, data) do
    case write(t, path, data) do
      :ok -> :ok
      {:error, reason} -> raise File.Error, reason: reason, action: "write to", path: path
    end
  end

  @doc "Entries of a directory: `%{name, type, size, mtime}`."
  def ls(t, path), do: Guest.file(t, "list", path)

  @doc "The path itself, not what a symlink points at."
  def lstat(t, path), do: Guest.file(t, "stat", path)

  @doc "Everything under a directory, `name` relative to it; symlinks listed, not followed."
  def walk(t, path), do: Guest.file(t, "walk", path)

  def rename(t, from, to), do: Guest.file(t, "rename", from, to: to, user: @user)

  def rm_rf(t, path) do
    case Guest.file(t, "remove", path) do
      {:error, :enoent} -> :ok
      other -> other
    end
  end

  def mkdir_p(t, path), do: Guest.file(t, "mkdir", path, user: @user)

  def exists?(t, path), do: match?({:ok, _}, lstat(t, path))
  def regular?(t, path), do: match?({:ok, %{type: :file}}, lstat(t, path))
  def dir?(t, path), do: match?({:ok, %{type: :dir}}, lstat(t, path))

  @doc "Hold `path` open for appending; see `Weaver.FS.Log`."
  def open_log(t, path), do: Weaver.FS.Log.open(t, path, @user)
end
