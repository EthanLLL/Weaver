defmodule Weaver.Nodes.Device do
  @moduledoc "A row of `devices`; see `Weaver.Nodes`."
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec, updated_at: false]

  schema "devices" do
    field(:tenant, :string)
    field(:name, :string)
    field(:token_hash, :string)
    field(:install_code_hash, :string)
    field(:install_code_expires_at, :utc_datetime_usec)
    field(:os, :string)
    field(:arch, :string)
    field(:hostname, :string)
    field(:version, :string)
    field(:last_seen_at, :utc_datetime_usec)
    timestamps()
  end

  @doc "Names are unique per tenant, whatever their case."
  def changeset(device_or_changeset),
    do:
      Ecto.Changeset.unique_constraint(Ecto.Changeset.change(device_or_changeset), :name,
        name: :devices_tenant_name_index
      )
end
