defmodule ArmchairMetropolistWeb.CityController do
  @moduledoc """
  Re-attaches a browser to an existing city.

  This cannot be a LiveView: a LiveView has no `conn` and cannot write the
  session, which is the only thing that persists the choice past this request.
  """

  use ArmchairMetropolistWeb, :controller

  alias ArmchairMetropolistWeb.CityCode

  @doc """
  Adopt `code` as this browser's city and redirect to the simulator.

  A well-formed code for a city that does not exist yields a new empty city under
  that id rather than an error: that is the same path a first-time visitor takes,
  so it needs no special handling, and a mistyped code gives an empty grid instead
  of a failure page. Checking existence first would cost a query on every entry
  and a second code path to test.
  """
  def enter(conn, %{"code" => code}) do
    if CityCode.valid?(code) do
      conn
      |> put_session(:city_id, code)
      |> redirect(to: ~p"/")
    else
      conn
      |> put_status(:not_found)
      |> put_view(html: ArmchairMetropolistWeb.ErrorHTML)
      |> render(:"404")
    end
  end
end
