defmodule Weaver.Repo.Migrations.Accounts do
  use Ecto.Migration

  def change do
    # Who may log in to `<name>.luozhen.cloud` (`Weaver.Accounts`). The VM is
    # the tenant's; where it is, is its directory on a host, not a row here.
    create table(:tenants, primary_key: false) do
      add :name, :text, primary_key: true
      # PBKDF2-SHA256: "pbkdf2-sha256$<iterations>$<salt>$<hash>", base64.
      add :password_hash, :text, null: false
      timestamps(updated_at: false)
    end

    # One-time sign-up codes, as SHA-256. Without one nobody gets a VM.
    create table(:invites, primary_key: false) do
      add :code_hash, :text, primary_key: true
      add :note, :text
      add :used_by, :text
      add :used_at, :utc_datetime_usec
      timestamps(updated_at: false)
    end
  end
end
