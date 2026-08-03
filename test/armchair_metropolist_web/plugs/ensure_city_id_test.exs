defmodule ArmchairMetropolistWeb.Plugs.EnsureCityIdTest do
  use ArmchairMetropolistWeb.ConnCase, async: true

  alias ArmchairMetropolistWeb.CityCode
  alias ArmchairMetropolistWeb.Plugs.EnsureCityId

  setup %{conn: conn} do
    {:ok, conn: Plug.Test.init_test_session(conn, %{})}
  end

  test "puts a valid id when the session has none", %{conn: conn} do
    conn = EnsureCityId.call(conn, [])

    assert conn |> Plug.Conn.get_session(:city_id) |> CityCode.valid?()
  end

  test "leaves an existing id alone", %{conn: conn} do
    conn = Plug.Conn.put_session(conn, :city_id, "existing")

    assert EnsureCityId.call(conn, []) |> Plug.Conn.get_session(:city_id) == "existing"
  end
end
