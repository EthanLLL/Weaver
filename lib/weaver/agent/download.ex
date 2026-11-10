defmodule Weaver.Agent.Download do
  @moduledoc """
  What the web side serves of a session's files, read out of the VM on the
  tenant's node and handed back whole. The checks are `Weaver.Agent.Files`'s
  and `Weaver.Agent.Output`'s; a session that is not running is not started
  just to read one of its files.
  """

  alias Weaver.Agent.{Files, Output, Store}
  alias Weaver.FS

  # Zipped in memory, so smaller than Loom's gigabyte.
  @zip_limit 256 * 1024 * 1024

  def session?(t, id), do: Store.valid_id?(id) and FS.dir?(t, Store.session_dir(id))

  @doc "Everything the session holds, for the file browser."
  def tree(t, id) do
    if session?(t, id),
      do: {:ok, %{files: Files.list(t, id), output: Output.list(t, id)}},
      else: :error
  end

  @doc "One attachment: `{:ok, %{name, data}}`."
  def attachment(t, id, name) do
    with true <- session?(t, id),
         {:ok, path} <- Files.resolve(t, id, name),
         {:ok, data} <- FS.read(t, path) do
      {:ok, %{name: Path.basename(path), data: data}}
    else
      _ -> :error
    end
  end

  @doc "One output file, or with `index: true` a directory's index.html: `{:ok, %{path, data}}`."
  def output(t, id, rel, opts \\ []) do
    with true <- session?(t, id),
         {:ok, path} <- locate(t, id, rel, opts[:index]),
         {:ok, data} <- FS.read(t, path) do
      {:ok, %{path: path, data: data}}
    else
      _ -> :error
    end
  end

  defp locate(t, id, rel, true) do
    case Output.resolve(t, id, rel) do
      {:ok, path} -> {:ok, path}
      :error -> Output.resolve(t, id, Path.join(rel, "index.html"))
    end
  end

  defp locate(t, id, rel, _), do: Output.resolve(t, id, rel)

  @doc "An output directory as a stored (uncompressed) zip: `{:ok, name, binary}`."
  def zip(t, id, rel) do
    with true <- session?(t, id),
         {:ok, dir} <- Output.resolve_dir(t, id, rel),
         [_ | _] = files <- Output.files_under(t, id, rel) do
      total = files |> Enum.map(&elem(&1, 1)) |> Enum.sum()

      if total > @zip_limit do
        {:error, :too_large}
      else
        root = Store.output_dir(id)
        base = Path.dirname(dir)

        # Named from the directory's parent, so the zip unpacks into one folder.
        entries =
          for {rel, _} <- files,
              path = Path.join(root, rel),
              {:ok, data} <- [FS.read(t, path)],
              do: {path |> Path.relative_to(base) |> String.to_charlist(), data}

        {:ok, {_, zip}} = :zip.create(~c"x.zip", entries, [:memory, uncompress: :all])
        {:ok, Path.basename(dir) <> ".zip", zip}
      end
    else
      {:error, _} = e -> e
      _ -> :error
    end
  end
end
