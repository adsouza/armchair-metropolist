defmodule ArmchairMetropolistWeb.PageController do
  use ArmchairMetropolistWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
