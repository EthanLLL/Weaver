defmodule Weaver.Search do
  @moduledoc """
  Full-text search over every session's transcript in a tenant's VM: Loom's,
  with ripgrep run where the transcripts are.

  rg is part of the platform, not the tenant's: `host/vm.sh` puts a static
  build at `/usr/local/lib/weaver/rg` on every boot, so it is there
  whatever the tenant has installed (or removed). It runs as the tenant's
  user, through `Weaver.Exec`, owned by the caller: a caller that is killed
  (a newer search from the same client, `WeaverWeb.LobbyChannel`) takes rg
  in the VM with it.

  What rg sees is JSON, so the query is matched in the form it is stored in;
  a line rg returns is then decoded, and only counts if it is something a
  person said or read: the user's messages and the agent's replies. See
  Loom's `Loom.Search` for the reasoning, unchanged here.
  """

  alias Weaver.Agent.Store

  @rg "/usr/local/lib/weaver/rg"
  @timeout 3_000
  @max_hits 100
  @kinds ["user", "assistant_text"]
  @context_before 40
  @context_after 80

  @doc """
  Hits for `query` in tenant `t`'s sessions, newest first: `%{id:, seq:, at:,
  kind:, before:, match:, after:}`. `{:error, :no_rg}` if the VM has no rg.
  """
  def content(t, query) when is_binary(query) do
    case String.trim(query) do
      "" -> {:ok, []}
      query -> run(t, query)
    end
  end

  defp run(t, query) do
    # As `Jason` writes it into the transcript, minus the quotes around it.
    needle = query |> Jason.encode!() |> String.slice(1..-2//1)

    argv = [
      @rg,
      "--json",
      "--fixed-strings",
      "--ignore-case",
      "--max-count",
      "200",
      # A session's own transcript and nothing else: one level down, so not
      # anything the agent wrote into `output/`, and not `.trash`, which is
      # hidden and so skipped by rg.
      "--glob",
      "events.jsonl",
      "--max-depth",
      "2",
      "--",
      needle,
      Store.data_dir()
    ]

    case Weaver.Exec.run(t, argv, [user: Weaver.FS.user()], @timeout) do
      # 1 is "nothing matched".
      {:ok, %{stdout: out, status: status}} when status in [0, 1] -> {:ok, hits(out, query)}
      # The guest could not start it.
      {:error, "fork/exec " <> _} -> {:error, :no_rg}
      {:ok, %{status: status}} -> {:error, {:rg_failed, status}}
      {:error, _} = error -> error
    end
  end

  defp hits(out, query) do
    pattern = Regex.compile!(Regex.escape(query), "iu")

    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&hit(&1, pattern))
    |> Enum.sort_by(& &1.at, :desc)
    |> Enum.take(@max_hits)
  end

  defp hit(line, pattern) do
    with {:ok, %{"type" => "match", "data" => data}} <- Jason.decode(line),
         %{"path" => %{"text" => path}, "lines" => %{"text" => text}} <- data,
         {:ok, %{"kind" => kind, "payload" => %{"text" => message}} = event} <- Jason.decode(text),
         true <- kind in @kinds and is_binary(message),
         [{start, len}] <- Regex.run(pattern, message, return: :index) do
      [
        %{
          id: path |> Path.dirname() |> Path.basename(),
          seq: event["seq"],
          at: event["at"],
          kind: kind,
          before: message |> binary_part(0, start) |> tail(@context_before),
          match: binary_part(message, start, len),
          after:
            message
            |> binary_part(start + len, byte_size(message) - start - len)
            |> String.slice(0, @context_after)
        }
      ]
    else
      _ -> []
    end
  end

  defp tail(text, n), do: text |> String.graphemes() |> Enum.take(-n) |> Enum.join()
end
