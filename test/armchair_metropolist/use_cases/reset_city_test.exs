defmodule ArmchairMetropolist.UseCases.ResetCityTest do
  use ExUnit.Case, async: true

  alias ArmchairMetropolist.Domain.Entities.CityMap
  alias ArmchairMetropolist.Domain.Entities.Node
  alias ArmchairMetropolist.UseCases.ResetCity

  test "returns a fresh city and the metrics of that city, not of the old one" do
    city =
      CityMap.new(40, 30)
      |> CityMap.put_node(%Node{Node.new(0, 0, :residential) | health: 0.0, status: :offline})
      |> CityMap.debit(150.0)

    city = %{city | tick: 99, injury_stock: 8.0, disease_stock: 12.0, crime_stock: 6.0}

    assert {:ok, %{city_map: reset, metrics: metrics}} = ResetCity.execute(city)

    assert reset == CityMap.new()

    # Computed from the *new* map, the same way AdvanceCityTick computes from the
    # post-tick map. Metrics of the old city here would leave the view rendering a
    # collapse banner over an empty grid.
    assert metrics.tick == 0
    assert metrics.node_count == 0
    assert metrics.money == 0.0
    assert metrics.injury_stock == 0.0
    assert metrics.disease_stock == 0.0
    assert metrics.crime_stock == 0.0
    assert reset.municipal_bond == nil
    assert reset.commercial_bond == nil
    refute metrics.stalled
    assert metrics.bankrupt
    refute ArmchairMetropolist.Domain.Entities.SimulationMetrics.game_over?(metrics)
  end
end
