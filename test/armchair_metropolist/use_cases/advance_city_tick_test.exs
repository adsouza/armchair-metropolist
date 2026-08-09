defmodule ArmchairMetropolist.UseCases.AdvanceCityTickTest do
  use ExUnit.Case, async: true

  alias ArmchairMetropolist.Domain.Entities.{CityMap, MunicipalBond, Node}
  alias ArmchairMetropolist.UseCases.AdvanceCityTick

  defp legacy_city(width, height) do
    %{CityMap.new(width, height) | municipal_bond: MunicipalBond.legacy(), money: 500.0}
  end

  test "returns the new map, the delta and consistent metrics" do
    map =
      legacy_city(40, 30)
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
             AdvanceCityTick.execute(legacy_city(40, 30))

    assert next.tick == 1
    assert delta == %{}
    assert metrics.avg_health == 0.0
  end
end
