defmodule ArmchairMetropolist.UseCases.SummarizeCityTest do
  @moduledoc """
  `SummarizeCity` exists so the OTP layer can obtain metrics without advancing the
  tick.

  It is not a convenience wrapper: `Infrastructure` is deliberately barred from
  `Domain.Services` by the boundary graph, so `CityEngine` physically cannot call
  `SimulationCalculator.metrics/1` itself. `UseCases` may, which is why this lives
  here. Before it existed the engine fell back to
  `SimulationMetrics.build(city_map, %{})`, leaving `resources` empty until the
  first tick landed.
  """
  use ExUnit.Case, async: true

  alias ArmchairMetropolist.Domain.Entities.{CityMap, Node}
  alias ArmchairMetropolist.UseCases.SummarizeCity

  # The `%CityMap{} =` match is load-bearing, not decoration: `Enum.reduce/3`
  # returns `dynamic()`, so without it the type checker cannot tell that a
  # `%CityMap{city_with(...) | tick: n}` update downstream is valid, and warns at
  # every such call site. Refining the type here fixes it once.
  defp city_with(nodes) do
    %CityMap{} = Enum.reduce(nodes, CityMap.new(40, 30), &CityMap.put_node(&2, &1))
  end

  test "reports every resource, not an empty map" do
    assert {:ok, metrics} = SummarizeCity.execute(city_with([Node.new(0, 0, :residential)]))

    assert Enum.sort(Map.keys(metrics.resources)) == Enum.sort(Node.resources())

    for {_resource, stats} <- metrics.resources do
      assert is_float(stats.supplied)
      assert is_float(stats.carried)
      assert is_float(stats.purchased)
      assert is_float(stats.demanded)
      assert is_float(stats.deficit)
      assert is_float(stats.satisfaction)
    end
  end

  test "does not advance the tick" do
    city = %CityMap{city_with([Node.new(0, 0, :residential)]) | tick: 7}

    assert {:ok, metrics} = SummarizeCity.execute(city)
    assert metrics.tick == 7, "summarising must be read-only; advancing is AdvanceCityTick's job"
  end

  test "node-level figures match the map it was given" do
    city =
      city_with([
        %Node{Node.new(0, 0, :residential) | health: 100.0, status: :online},
        %Node{Node.new(1, 0, :residential) | health: 10.0, status: :offline}
      ])

    assert {:ok, metrics} = SummarizeCity.execute(city)
    assert metrics.node_count == 2
    assert metrics.offline_count == 1
    assert_in_delta metrics.avg_health, 55.0, 0.001
  end

  test "an empty city summarises without raising" do
    assert {:ok, metrics} = SummarizeCity.execute(CityMap.new(40, 30))
    assert metrics.node_count == 0
    assert metrics.avg_health === 0.0
    # Baseline municipal capacity means nothing is in deficit on an empty grid.
    assert metrics.resources.power.satisfaction == 1.0
  end

  test "reports a deficit when demand exceeds supply" do
    # Six unfunded residential draw 90 power with no local or baseline supply.
    city = %{city_with(for(x <- 0..5, do: Node.new(x, 0, :residential))) | money: 0.0}

    assert {:ok, metrics} = SummarizeCity.execute(city)
    assert metrics.resources.power.satisfaction == 0.0
    assert_in_delta metrics.resources.power.deficit, 90.0, 0.001
  end
end
