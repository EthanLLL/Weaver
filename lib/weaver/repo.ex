defmodule Weaver.Repo do
  @moduledoc """
  The platform's database, Aurora PostgreSQL `weaver`, one for every node.
  See `config/config.exs` for what belongs here rather than in a VM.
  """
  use Ecto.Repo, otp_app: :weaver, adapter: Ecto.Adapters.Postgres
end
