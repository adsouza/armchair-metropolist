defmodule ArmchairMetropolistWeb.Plugs.EnsureCityId do
  @moduledoc """
  Puts a city id in the session when there is not one already.

  The session is a signed cookie (`endpoint.ex`), so a visitor can read their id
  but cannot forge another — which matters, because the id is the only thing
  standing between someone and a city.
  """

  @behaviour Plug

  import Plug.Conn

  alias ArmchairMetropolistWeb.CityCode

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case get_session(conn, :city_id) do
      nil -> put_session(conn, :city_id, CityCode.generate())
      _existing -> conn
    end
  end
end
