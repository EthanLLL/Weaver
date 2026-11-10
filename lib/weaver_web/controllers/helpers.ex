defmodule WeaverWeb.At do
  @moduledoc """
  `at(conn, m, f, a)`: `apply(m, f, [tenant | a])` on the tenant's node, which
  is how every controller and channel reaches a tenant's sessions and files.
  """

  def at(%Plug.Conn{assigns: %{tenant: t}}, m, f, a), do: at(t, m, f, a)
  def at(%Phoenix.Socket{assigns: %{tenant: t}}, m, f, a), do: at(t, m, f, a)
  def at(t, m, f, a) when is_binary(t), do: Weaver.Tenant.at(t, m, f, [t | a])
end
