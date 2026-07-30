defmodule ArmchairMetropolist.Domain.DomainPropertiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ArmchairMetropolist.CityGenerators
  alias ArmchairMetropolist.Domain.Entities.Node
  alias ArmchairMetropolist.Domain.Services.SimulationCalculator, as: Calc

  property "health always stays within 0.0..100.0 across many ticks" do
    check all city <- CityGenerators.city(), ticks <- StreamData.integer(1..25) do
      final =
        Enum.reduce(1..ticks, city, fn _, acc ->
          {next, _} = Calc.advance_tick(acc)
          next
        end)

      for {_id, node} <- final.nodes do
        assert node.health >= 0.0
        assert node.health <= 100.0
      end
    end
  end

  property "delta contains exactly the nodes whose display signature changed" do
    check all city <- CityGenerators.city() do
      before_sigs = Map.new(city.nodes, fn {id, n} -> {id, Node.display_signature(n)} end)
      {after_map, delta} = Calc.advance_tick(city)
      after_sigs = Map.new(after_map.nodes, fn {id, n} -> {id, Node.display_signature(n)} end)

      expected =
        for {id, sig} <- after_sigs, Map.fetch!(before_sigs, id) != sig, into: MapSet.new(), do: id

      assert MapSet.new(Map.keys(delta)) == expected
    end
  end

  property "advance_tick is deterministic" do
    check all city <- CityGenerators.city() do
      assert Calc.advance_tick(city) == Calc.advance_tick(city)
    end
  end

  property "advance_tick neither creates nor destroys nodes, and tick increases" do
    check all city <- CityGenerators.city() do
      {next, _} = Calc.advance_tick(city)
      assert map_size(next.nodes) == map_size(city.nodes)
      assert Map.keys(next.nodes) |> Enum.sort() == Map.keys(city.nodes) |> Enum.sort()
      assert next.tick == city.tick + 1
    end
  end

  property "status is always consistent with health" do
    check all city <- CityGenerators.city() do
      {next, _} = Calc.advance_tick(city)

      for {_id, node} <- next.nodes do
        assert node.status == Node.status_for(node.health)
      end
    end
  end
end
