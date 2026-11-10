defmodule Weaver.Agent.Output do
  @moduledoc """
  The files an agent produces for the user: where it is told to put them, how
  the session notices them, and which of them a download may name.

  The mirror image of `Weaver.Agent.Files`. Attachments go in
  `<session_dir>/files/`, deliverables come out of `<session_dir>/output/`, and
  deleting a session takes both with it.

  ## The agent is told, not watched

  Both backends write wherever they like, so the only way to know which file is
  meant for the user is to agree on a place in advance. `Weaver.Agent.Instructions`
  is that agreement, handed to the backend as part of its system prompt.

  ## Noticed at the end of a turn, not as it happens

  The session snapshots the directory when it starts and compares again when a
  turn ends — done, failed or interrupted — and announces whatever is new or
  changed as one event. Not after every tool call: a tool result only says that
  one command ended, a script that rewrites `report.xlsx` three times would
  announce it three times, and the end of the turn is the point at which the
  model itself considers the file finished.

  This is also why nothing depends on what the model writes in its reply. A
  reply that forgets to mention the file, or links it wrongly, still leaves the
  file on the card.

  Ported from Loom: the directory is in the tenant's VM. A snapshot is one
  `walk` of it through the guest, which lists symlinks without following
  them, so nothing reached through one is ever a deliverable.
  """

  alias Weaver.Agent.Store
  alias Weaver.FS

  # One turn producing more than this is a build directory dumped in by mistake,
  # not a set of deliverables. The card names the first ones and says so.
  @max_listed 50

  @doc "Make sure the directory exists, so the agent can write straight into it."
  def ensure_dir(t, session_id) do
    FS.mkdir_p(t, Store.output_dir(session_id))
    :ok
  end

  @doc """
  The directory as it stands: relative path ↦ `{size, mtime}`.

  Regular files only, hidden ones skipped — Office's `~$report.xlsx` lock files
  and editor swap files are not deliverables. `lstat`, so a symlink is skipped
  too: `resolve/2` would refuse to serve it.
  """
  def snapshot(t, session_id) do
    case FS.walk(t, Store.output_dir(session_id)) do
      {:ok, entries} ->
        for %{name: rel, type: :file, size: size, mtime: mtime} <- entries,
            not hidden?(rel),
            into: %{},
            do: {rel, {size, div(mtime, 1000)}}

      {:error, _} ->
        %{}
    end
  end

  @doc """
  The whole directory for the file browser: one entry per file, by path, with
  its size and mtime (posix seconds). The same files `resolve/2` would serve.
  """
  def list(t, session_id) do
    t
    |> snapshot(session_id)
    |> Enum.map(fn {rel, {size, mtime}} -> %{path: rel, size: size, mtime: mtime} end)
    |> Enum.sort_by(& &1.path)
  end

  @doc """
  What is new or different in `now` compared with `before`, described for the
  transcript as `%{files: entries, more: n, open: path | nil}`.

  One entry per top-level name in the directory, not per file: a file directly
  in `output/` is itself, and a directory is one entry however many files it
  holds — a comic chapter of forty pages is one card, not forty. A directory
  counts as changed when anything in it did. One with an `index.html` is a page,
  and opens in the canvas; one without is offered as a zip.

  `open` is the page the canvas should show without being asked: the most
  recently written `index.html` among the changes, at the top level or one
  directory down. Only pages open on their own; everything else waits for a
  click.

  A deleted file is not reported: the card announces downloads, and there is
  nothing to download.
  """
  def changes(before, now) do
    changed = Enum.reject(now, fn {rel, stamp} -> Map.get(before, rel) == stamp end)

    entries =
      changed
      |> Enum.group_by(fn {rel, _} -> top(rel) end)
      |> Enum.sort_by(fn {top, _} -> top end)
      |> Enum.map(fn {top, _} -> entry(top, before, now) end)

    listed = Enum.take(entries, @max_listed)

    %{files: listed, more: length(entries) - length(listed), open: page_to_open(changed, now)}
  end

  defp top(rel), do: rel |> Path.split() |> hd()

  defp entry(top, before, now) do
    case Map.fetch(now, top) do
      {:ok, {size, _mtime}} ->
        %{
          kind: "file",
          name: top,
          path: top,
          size: size,
          content_type: MIME.from_path(top),
          updated: Map.has_key?(before, top)
        }

      :error ->
        inside = for {rel, stamp} <- now, under?(rel, top), do: {rel, stamp}
        index = Path.join(top, "index.html")

        %{
          kind: "dir",
          name: top,
          path: top,
          size: inside |> Enum.map(fn {_, {size, _}} -> size end) |> Enum.sum(),
          files: length(inside),
          index: if(Map.has_key?(now, index), do: index),
          content_type: "inode/directory",
          updated: Enum.any?(Map.keys(before), &under?(&1, top))
        }
    end
  end

  defp under?(rel, top), do: String.starts_with?(rel, top <> "/")

  # The newest `index.html` among the pages that changed. A page's images being
  # rewritten while its index stayed the same still changes what it shows.
  defp page_to_open(changed, now) do
    changed
    |> Enum.map(fn {rel, _} -> page_of(rel) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.filter(&Map.has_key?(now, &1))
    |> Enum.max_by(fn index -> elem(Map.fetch!(now, index), 1) end, fn -> nil end)
  end

  defp page_of("index.html"), do: "index.html"

  defp page_of(rel) do
    case Path.split(rel) do
      [_only] -> nil
      [top | _] -> Path.join(top, "index.html")
    end
  end

  @doc """
  The absolute path of one of this session's output *directories*, for a zip.
  Same rules as `resolve/2`, for a directory instead of a file.
  """
  def resolve_dir(t, session_id, rel) do
    dir = session_id |> Store.output_dir() |> Path.expand()
    path = Path.expand(to_string(rel), dir)

    cond do
      not String.starts_with?(path, dir <> "/") -> :error
      hidden?(Path.relative_to(path, dir)) -> :error
      not inside?(t, path, dir, :dir) -> :error
      true -> {:ok, path}
    end
  end

  @doc """
  The absolute path a download names, if it really is one of this session's
  outputs.

  `rel` comes from a URL, so it is hostile: `..`, an absolute path, a symlink
  out. Expanded and checked against the directory rather than pattern-matched,
  the same rule `Weaver.Agent.Files.verify/2` applies to attachments.
  """
  def resolve(t, session_id, rel) do
    dir = session_id |> Store.output_dir() |> Path.expand()
    path = Path.expand(to_string(rel), dir)

    cond do
      not String.starts_with?(path, dir <> "/") -> :error
      hidden?(Path.relative_to(path, dir)) -> :error
      # A symlink the agent left pointing elsewhere would otherwise serve
      # whatever it points at.
      not inside?(t, path, dir, :file) -> :error
      true -> {:ok, path}
    end
  end

  @doc """
  Delete one output, a file or a whole directory, for the file browser.

  Only what `resolve/2` or `resolve_dir/2` would hand out: nothing hidden,
  nothing through a symlink, never the output directory itself.
  """
  def delete(t, session_id, rel) do
    case resolve_any(t, session_id, rel) do
      {:ok, path} ->
        FS.rm_rf(t, path)

      :error ->
        :error
    end
  end

  @doc """
  Rename one output in place, keeping its directory: `name` is the new last
  component, not a path. Returns the new path relative to the output directory.
  Refuses a name that is taken rather than overwriting what is there.
  """
  def rename(t, session_id, rel, name) do
    with {:ok, path} <- resolve_any(t, session_id, rel),
         {:ok, name} <- valid_name(name),
         dest = Path.join(Path.dirname(path), name),
         false <- FS.exists?(t, dest) && :exists,
         :ok <- FS.rename(t, path, dest) do
      dir = session_id |> Store.output_dir() |> Path.expand()
      {:ok, Path.relative_to(dest, dir)}
    else
      :exists -> {:error, :exists}
      {:error, reason} -> {:error, reason}
      :error -> :error
    end
  end

  @doc """
  A new name for a file or directory, as typed: one component, nothing that
  would hide it (a leading dot) or reach elsewhere.
  """
  def valid_name(name) when is_binary(name) do
    name = String.trim(name)

    cond do
      name in ["", ".", ".."] -> {:error, :bad_name}
      String.starts_with?(name, ".") or String.starts_with?(name, "~$") -> {:error, :bad_name}
      String.match?(name, ~r/[\x00-\x1f\/\\]/u) -> {:error, :bad_name}
      byte_size(name) > 255 -> {:error, :bad_name}
      true -> {:ok, name}
    end
  end

  def valid_name(_name), do: {:error, :bad_name}

  defp resolve_any(t, session_id, rel) do
    with :error <- resolve(t, session_id, rel), do: resolve_dir(t, session_id, rel)
  end

  @doc """
  Every file a zip of `rel` may contain, relative to the output directory: the
  same files `resolve/2` would serve one at a time, and nothing else.
  """
  def files_under(t, session_id, rel) do
    prefix = String.trim_trailing(rel, "/") <> "/"

    t
    |> snapshot(session_id)
    |> Enum.filter(fn {path, _} -> String.starts_with?(path, prefix) end)
    |> Enum.map(fn {path, {size, _}} -> {path, size} end)
    |> Enum.sort()
  end

  defp hidden?(rel) do
    rel
    |> Path.split()
    |> Enum.any?(&(String.starts_with?(&1, ".") or String.starts_with?(&1, "~$")))
  end

  # No component between the directory and the target may be a symlink, and
  # the target is a `type`. Stricter than resolving the link and checking where
  # it lands, and nothing an agent writes as a deliverable needs one. (The
  # snapshot needs no such check: `walk` never follows a symlink.)
  defp inside?(t, path, dir, type) do
    components =
      path
      |> Path.relative_to(dir)
      |> Path.split()
      |> Enum.scan(dir, &Path.join(&2, &1))

    {parents, [last]} = Enum.split(components, -1)

    Enum.all?(parents, &match?({:ok, %{type: :dir}}, FS.lstat(t, &1))) and
      match?({:ok, %{type: ^type}}, FS.lstat(t, last))
  end
end
