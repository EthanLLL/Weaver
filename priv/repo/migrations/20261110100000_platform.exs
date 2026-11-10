defmodule Weaver.Repo.Migrations.Platform do
  use Ecto.Migration

  # Rows are keyed by tenant: the name in its host, `<tenant>.luozhen.cloud`.
  def change do
    # A tenant's own machines (`Weaver.Nodes`). Being online is not here: it
    # is the device's channel, in a `:pg` group.
    create table(:devices, primary_key: false) do
      add :id, :text, primary_key: true
      add :tenant, :text, null: false
      add :name, :text, null: false
      # SHA-256 of the device's token, and of its one-time install code.
      add :token_hash, :text
      add :install_code_hash, :text
      add :install_code_expires_at, :utc_datetime_usec
      add :os, :text
      add :arch, :text
      add :hostname, :text
      add :version, :text
      add :last_seen_at, :utc_datetime_usec
      timestamps(updated_at: false)
    end

    create unique_index(:devices, [:tenant, "lower(name)"], name: :devices_tenant_name_index)
    create unique_index(:devices, [:token_hash])
    create unique_index(:devices, [:install_code_hash])

    # Browsers that turned notifications on (`Weaver.Push`).
    create table(:push_subscriptions, primary_key: false) do
      add :tenant, :text, null: false, primary_key: true
      add :endpoint, :text, null: false, primary_key: true
      add :p256dh, :text, null: false
      add :auth, :text, null: false
      add :origin, :text, null: false
      timestamps(updated_at: false)
    end

    # Scheduled prompts (`Weaver.Cron`).
    create table(:cron_jobs, primary_key: false) do
      add :id, :text, primary_key: true
      add :tenant, :text, null: false
      add :name, :text, null: false
      add :cron, :text, null: false
      add :target, :text, null: false
      add :prompt, :text, null: false
      add :last_run_at, :utc_datetime_usec
      add :last_error, :text
      timestamps(updated_at: false)
    end

    create index(:cron_jobs, [:tenant])
  end
end
