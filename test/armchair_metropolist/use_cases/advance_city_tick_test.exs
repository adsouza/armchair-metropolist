defmodule ArmchairMetropolist.UseCases.AdvanceCityTickTest do
  use ExUnit.Case, async: true

  alias ArmchairMetropolist.Domain.Entities.{CityMap, Node}
  alias ArmchairMetropolist.UseCases.AdvanceCityTick

  test "returns the new map, the delta and consistent metrics" do
    map =
      CityMap.new(40, 30)
      |> CityMap.put_node(Node.new(0, 0, :residential))
      |> CityMap.put_node(Node.new(1, 0, :residential))

    assert {:ok, %{city_map: next, delta: delta, metrics: metrics}} =
             AdvanceCityTick.execute(map)

    assert next.tick == 1
    assert metrics.tick == 1
    assert metrics.node_count == 2
    assert is_map(delta)
  end

  # An empty grid is the hydration fallback, so this is the startup path.
  test "advances an empty city without raising" do
    assert {:ok, %{city_map: next, delta: delta, metrics: metrics}} =
             AdvanceCityTick.execute(CityMap.new(40, 30))

    assert next.tick == 1
    assert delta == %{}
    assert metrics.avg_health == 0.0
  end
end
