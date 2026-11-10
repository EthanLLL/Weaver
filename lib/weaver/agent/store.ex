defmodule Weaver.Agent.Store do
  @moduledoc """
  Persistence for a tenant's sessions, in their VM. Loom's layout, unchanged,
  under the VM user's home:

      ~/.loom/sessions/<id>/meta.json     header, rewritten in place
      ~/.loom/sessions/<id>/events.jsonl  normalized transcript events, append-only
      ~/.loom/sessions/<id>/files/…       what the user attached to the session
      ~/.loom/sessions/<id>/output/…      what the agent made for the user
      ~/.loom/sessions/.trash/<id>.<ms>/  a deleted session, kept whole

  Paths are the same in every VM, so they need no tenant; reading and writing
  do, and go through `Weaver.FS`.

  `events.jsonl` is display truth only, as in Loom: the conversation itself is
  the backend's own, in the VM's `~/.claude/projects/`. Each line is synced by
  the guest before the next is written (`Weaver.FS.Log`).
  """

  require Logger

  alias Weaver.FS

  @meta_file "meta.json"
  @events_file "events.jsonl"

  # ── Layout ────────────────────────────────────────────────────────────────

  @doc "Loom's own directory in the VM."
  def home, do: Path.join(FS.home(), ".loom")

  def data_dir, do: Path.join(home(), "sessions")
  def session_dir(id), do: Path.join(data_dir(), id)
  def files_dir(id), do: Path.join(session_dir(id), "files")
  def output_dir(id), do: Path.join(session_dir(id), "output")
  def trash_dir, do: Path.join(data_dir(), ".trash")

  # ── Meta ──────────────────────────────────────────────────────────────────

  @doc "Write (or rewrite) a session's header. The guest writes it atomically."
  def write_meta(t, id, meta) do
    FS.write!(t, Path.join(session_dir(id), @meta_file), Jason.encode_to_iodata!(meta))
  end

  @doc "One session's header, or `:error`. Never raises."
  def read_meta(t, id) do
    with {:ok, body} <- FS.read(t, Path.join(session_dir(id), @meta_file)),
         {:ok, raw} <- Jason.decode(body),
         %{"id" => _} <- raw do
      {:ok, Map.new(raw, fn {key, value} -> {atomize(key), value} end)}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  @doc "Every session header in the VM, oldest first."
  def list_metas(t) do
    case FS.ls(t, data_dir()) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&(&1.type == :dir and not String.starts_with?(&1.name, ".")))
        |> Enum.map(&read_meta(t, &1.name))
        |> Enum.flat_map(fn
          {:ok, meta} -> [meta]
          :error -> []
        end)
        |> Enum.sort_by(& &1[:created_at])

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.warning("Weaver.Agent.Store cannot list #{t}'s sessions: #{inspect(reason)}")
        []
    end
  end

  @doc """
  A summary of every session, from its header alone: what the sidebar shows
  of a session whose process is not running. The same shape a running one
  broadcasts (`Weaver.Agent.Session`).
  """
  def list_summaries(t), do: Enum.flat_map(list_metas(t), &summary/1)

  defp summary(meta) do
    case Weaver.Agent.Backend.parse(Weaver.Agent.Backend.meta_get(meta, :backend)) do
      {:ok, backend} ->
        queue = if is_list(meta[:queue]), do: meta[:queue], else: []

        [
          %{
            id: meta[:id],
            backend: backend,
            backend_label: Weaver.Agent.Backend.label(backend),
            title: meta[:title],
            directory: meta[:directory] || "",
            created_at: meta[:created_at],
            last_active_at: meta[:last_active_at] || meta[:created_at],
            # At rest, "running" can only mean a turn that went with a restart,
            # which is how the session will come back.
            status:
              if(meta[:status] in ["running", "starting", "interrupted"],
                do: :interrupted,
                else: :idle
              ),
            queued: length(queue),
            queue: queue,
            usage: meta[:usage],
            context_tokens: meta[:context_tokens] || 0,
            context_window: meta[:context_window],
            turns: meta[:turns] || 0,
            seq: meta[:seq] || 0
          }
        ]

      :error ->
        []
    end
  end

  @doc """
  Move a session's directory into the trash, as `<id>.<unix ms>`. Nothing is
  removed. Refuses anything that is not one plain path segment.
  """
  def delete_session(t, id) do
    if valid_id?(id) do
      target = Path.join(trash_dir(), "#{id}.#{System.system_time(:millisecond)}")

      case FS.rename(t, session_dir(id), target) do
        :ok -> :ok
        {:error, :enoent} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :invalid_id}
    end
  end

  def valid_id?(id) do
    is_binary(id) and id != "" and not String.starts_with?(id, ".") and Path.basename(id) == id
  end

  # ── Append-only log ───────────────────────────────────────────────────────

  @doc "Open a session's transcript for appending, held by the session for its life."
  def open_logs(t, id) do
    with {:ok, events} <- FS.open_log(t, Path.join(session_dir(id), @events_file)) do
      {:ok, %{events: events}}
    end
  end

  def close_logs(nil), do: :ok
  def close_logs(%{events: events}), do: Weaver.FS.Log.close(events)

  def append_event(nil, _event), do: :ok

  def append_event(%{events: log}, event),
    do: Weaver.FS.Log.append(log, [Jason.encode_to_iodata!(event), "\n"])

  # ── Reading back ──────────────────────────────────────────────────────────

  @doc "A session's transcript events, newest first, at most `limit`. See Loom."
  def read_events(t, id, limit) do
    case FS.read(t, Path.join(session_dir(id), @events_file)) do
      {:ok, body} ->
        body
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, term} -> [term]
            # A torn trailing line from a crash mid-append.
            {:error, _} -> []
          end
        end)
        |> Enum.reverse()
        |> Enum.take(limit)
        |> Enum.flat_map(fn raw ->
          case decode_event(raw) do
            {:ok, event} -> [event]
            :error -> []
          end
        end)

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.warning("Weaver.Agent.Store cannot read #{t}/#{id} events: #{inspect(reason)}")
        []
    end
  end

  defp decode_event(%{"seq" => seq, "at" => at, "kind" => kind, "payload" => payload})
       when is_integer(seq) and is_binary(kind) and is_map(payload) do
    {:ok, %{seq: seq, at: at, kind: atomize(kind), payload: decode_payload(payload)}}
  end

  defp decode_event(_), do: :error

  # Only the top-level payload keys become atoms; `input` and `details` hold
  # opaque nested data.
  defp decode_payload(payload) do
    Map.new(payload, fn {key, value} -> {atomize(key), decode_value(key, value)} end)
  end

  defp decode_value("status", value) when is_binary(value), do: atomize(value)
  defp decode_value(_key, value), do: value

  defp atomize(string) do
    String.to_existing_atom(string)
  rescue
    ArgumentError -> string
  end
end
