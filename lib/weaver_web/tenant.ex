defmodule WeaverWeb.Tenant do
  @moduledoc "Which tenant a request is for: `<tenant>.<domain>`, if that tenant exists."

  def from_host(host) when is_binary(host) do
    suffix = "." <> Application.fetch_env!(:weaver, :domain)
    tenant = String.replace_suffix(host, suffix, "")

    with true <- tenant != host and tenant =~ ~r/\A[a-z0-9-]+\z/,
         true <- Weaver.Tenant.exists?(tenant) do
      {:ok, tenant}
    else
      _ -> :error
    end
  end

  def from_host(_), do: :error
end
