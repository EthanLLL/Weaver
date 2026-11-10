defmodule Weaver.Agent.Files do
  @moduledoc """
  The files a user attaches to a session: where they land, and how the model is
  told about them.

  Uploads are written to `<session_dir>/files/<name>` (see
  `Weaver.Agent.Store.files_dir/1`) and nothing is read, decoded or converted
  here. The absolute path goes to the model in the message text and the backend
  reads it with its own tools — Claude Code's `Read` renders an image, Codex has
  `view_image` — which costs one tool round-trip and in exchange:

    - works for every file type, not just the ones we taught it about;
    - never base64s a 20 MB screenshot through stdio or JSON-RPC;
    - needs no second content format in either adapter, so `run_turn/2` still
      takes a string.

  ## Display text and model text are not the same string

  The transcript event keeps what the user actually typed plus the attachment
  list as structured data, so a bubble can show `shot.png` as a chip. Only the
  message handed to the backend carries the paths — see `prompt/2`. Putting the
  paths in the displayed text instead would mean every attachment permanently
  turns the user's own sentence into 70 characters of absolute path.

  ## A path is a capability

  The client echoes back the path that `store/2` returned, and the model will
  read whatever we name — so `verify/2` refuses anything that is not inside this
  session's own files directory. The agent runs unsandboxed and could read that
  file on its own initiative anyway; the point is that a client cannot make it
  happen silently by rewriting one field.

  Ported from Loom: the files are in the tenant's VM, so every function takes
  the tenant and goes through `Weaver.FS`. An upload arrives on whichever
  node the browser reached, as a temp file there, so `store/3` takes its
  contents rather than its path.
  """

  alias Weaver.Agent.Store
  alias Weaver.FS

  # Generous for a screenshot or a log, small enough that a mis-drop of a video
  # fails fast instead of filling the disk.
  @max_bytes 25 * 1024 * 1024
  @max_name_length 100

  @doc """
  Store one upload under `session_id` and describe where it went.

  Returns `{:error, :too_large}` or `{:error, :empty}` rather than raising: a
  bad file in a multi-file drop should report itself, not take the request down.
  """
  def store(t, session_id, %{filename: filename, data: data}) do
    with {:ok, size} <- measure(data) do
      dir = Store.files_dir(session_id)
      name = unique(t, dir, safe_name(filename))
      dest = Path.join(dir, name)

      with :ok <- FS.write(t, dest, data) do
        {:ok, %{name: name, path: dest, size: size, content_type: MIME.from_path(name)}}
      end
    end
  end

  @doc """
  Check that each path really is one of this session's attachments, and
  describe it.

  Refuses on the first path that is not, because a submit carrying one bogus
  path is a client bug or an attempt — either way the user should hear about it
  rather than have it quietly dropped.
  """
  def verify(_t, _session_id, []), do: {:ok, []}

  def verify(t, session_id, paths) when is_list(paths) do
    dir = session_id |> Store.files_dir() |> Path.expand()

    paths
    |> Enum.reduce_while({:ok, []}, fn raw, {:ok, acc} ->
      path = raw |> to_string() |> Path.expand()

      with true <- String.starts_with?(path, dir <> "/"),
           {:ok, %{type: :file, size: size}} <- FS.lstat(t, path) do
        {:cont, {:ok, [describe(path, size) | acc]}}
      else
        _ -> {:halt, {:error, {:not_an_attachment, to_string(raw)}}}
      end
    end)
    |> case do
      {:ok, files} -> {:ok, Enum.reverse(files)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The message the backend receives: what the user typed, then the paths.

  The model is told these are local files it may read, because otherwise a bare
  path in a sentence is ambiguous — it could be a file the user wants *written*.
  """
  def prompt(text, []), do: text

  def prompt(text, files) do
    paths = Enum.map_join(files, "\n", &"- #{&1.path}")

    header =
      "Attached #{length(files)} file#{if length(files) == 1, do: "", else: "s"} " <>
        "on this machine — read #{if length(files) == 1, do: "it", else: "them"} from these paths:"

    [String.trim(text), header, paths]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  @doc """
  Every attachment the session has, for the file browser: stored name, size
  and mtime (posix seconds), by name.

  The directory is flat — `store/2` never makes subdirectories — so this is one
  `ls`. Hidden files and anything that is not a regular file are skipped, the
  same files `verify/2` would refuse to hand back.
  """
  def list(t, session_id) do
    case FS.ls(t, Store.files_dir(session_id)) do
      {:ok, entries} ->
        for %{name: name, type: :file, size: size, mtime: mtime} <-
              Enum.sort_by(entries, & &1.name),
            not String.starts_with?(name, "."),
            do: %{path: name, size: size, mtime: div(mtime, 1000)}

      {:error, _} ->
        []
    end
  end

  @doc """
  Delete one attachment by its stored name. What `verify/2` would accept, and
  nothing else.

  The message that sent it keeps its chip, which then has nothing to show.
  """
  def delete(t, session_id, name) do
    with {:ok, path} <- resolve(t, session_id, name), do: FS.rm_rf(t, path)
  end

  @doc """
  Rename one attachment. The name is checked as an output's is
  (`Weaver.Agent.Output.valid_name/1`), and a taken one is refused.
  """
  def rename(t, session_id, name, new_name) do
    with {:ok, path} <- resolve(t, session_id, name),
         {:ok, new_name} <- Weaver.Agent.Output.valid_name(new_name),
         dest = Path.join(Path.dirname(path), new_name),
         false <- FS.exists?(t, dest) && :exists,
         :ok <- FS.rename(t, path, dest) do
      {:ok, new_name}
    else
      :exists -> {:error, :exists}
      other -> other
    end
  end

  def resolve(t, session_id, name) do
    case verify(t, session_id, [Path.join(Store.files_dir(session_id), to_string(name))]) do
      {:ok, [file]} -> {:ok, file.path}
      _ -> {:error, :not_found}
    end
  end

  @doc """
  A name for a session whose first message was an attachment with no words.

  Without it such a session shows up in the sidebar as an opaque id.
  """
  def title(files) do
    files |> Enum.map_join(", ", & &1.name) |> String.slice(0, 80)
  end

  # ── Internals ─────────────────────────────────────────────────────────────

  defp describe(path, size) do
    %{name: Path.basename(path), path: path, size: size, content_type: MIME.from_path(path)}
  end

  defp measure(data) do
    case byte_size(data) do
      0 -> {:error, :empty}
      size when size > @max_bytes -> {:error, :too_large}
      size -> {:ok, size}
    end
  end

  # The filename comes from the client, so it is a hostile string: `../../`, a
  # NUL, a Windows path, or four kilobytes of nothing. Letters are kept as they
  # are — including CJK, which the author's filenames are full of — and anything
  # that could mean "a directory" or confuse a shell is replaced.
  defp safe_name(filename) do
    filename
    |> to_string()
    |> Path.basename()
    |> String.replace(~r/[\x00-\x1f\/\\:*?"<>|]/u, "_")
    |> String.trim()
    |> clamp()
    |> case do
      "" -> "file"
      "." -> "file"
      ".." -> "file"
      name -> name
    end
  end

  # Truncate the stem, not the extension: the extension is what tells the
  # backend (and the model) what it is looking at.
  defp clamp(name) do
    if String.length(name) <= @max_name_length do
      name
    else
      ext = Path.extname(name)
      stem = String.slice(Path.basename(name, ext), 0, @max_name_length - String.length(ext))
      stem <> ext
    end
  end

  defp unique(t, dir, name) do
    if FS.exists?(t, Path.join(dir, name)), do: unique(t, dir, name, 1), else: name
  end

  defp unique(t, dir, name, n) do
    ext = Path.extname(name)
    candidate = "#{Path.basename(name, ext)}-#{n}#{ext}"
    if FS.exists?(t, Path.join(dir, candidate)), do: unique(t, dir, name, n + 1), else: candidate
  end
end
