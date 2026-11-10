defmodule Weaver.Cron.Job do
  @moduledoc "A row of `cron_jobs`; see `Weaver.Cron`."
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "cron_jobs" do
    field :tenant, :string
    field :name, :string
    field :cron, :string
    field :target, :string
    field :prompt, :string
    field :last_run_at, :utc_datetime_usec
    field :last_error, :string
    timestamps()
  end
end
