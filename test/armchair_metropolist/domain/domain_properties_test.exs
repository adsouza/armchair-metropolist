defmodule ArmchairMetropolist.Domain.DomainPropertiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ArmchairMetropolist.CityGenerators
  alias ArmchairMetropolist.Domain.Entities.Node
  alias ArmchairMetropolist.Domain.Services.SimulationCalculator, as: Calc

  # Mirrored from SimulationCalculator on purpose: the property below is an
  # independent oracle, so it must not read the rates from the module it checks.
  @regen_per_tick 1.0
  @decay_per_tick 6.0
  @min_health 0.0
  @max_health 100.0

  property "health always stays within 0.0..100.0 across many ticks" do
    check all(city <- CityGenerators.city(), ticks <- StreamData.integer(1..25)) do
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
    check all(city <- CityGenerators.city()) do
      before_sigs = Map.new(city.nodes, fn {id, n} -> {id, Node.display_signature(n)} end)
      {after_map, delta} = Calc.advance_tick(city)
      after_sigs = Map.new(after_map.nodes, fn {id, n} -> {id, Node.display_signature(n)} end)

      expected =
        for {id, sig} <- after_sigs,
            Map.fetch!(before_sigs, id) != sig,
            into: MapSet.new(),
            do: id

      assert MapSet.new(Map.keys(delta)) == expected
    end
  end

  # Replaces an `advance_tick(city) == advance_tick(city)` tautology, which no
  # deterministic implementation could ever fail. This is the same intent —
  # "every node within a tick sees identical city-wide conditions" — expressed as
  # an independent oracle instead: the expected health of *every* node is derived
  # from one set of pre-tick stats, so an implementation that recomputed them as
  # it walked the node map would diverge on every node but the first.
  #
  # Note that permuting the insertion order, the obvious way to write this, would
  # be another tautology: `CityMap.nodes` is a plain map keyed by node id, and
  # Erlang maps with equal key sets are *the same term* with the same iteration
  # order however they were built. Both orders would hand `advance_tick/1`
  # literally equal input. Verified by mutation - see the F5 evidence in
  # .superpowers/sdd/2026-07-29-city-infrastructure-simulator/final-fix-report.md.
  property "every node advances from one set of pre-tick, city-wide stats" do
    check all(city <- CityGenerators.city()) do
      stats = Calc.resource_stats(city)
      {next, _delta} = Calc.advance_tick(city)

      for {id, node} <- city.nodes do
        assert_in_delta Map.fetch!(next.nodes, id).health,
                        expected_health(node, stats),
                        1.0e-9
      end
    end
  end

  property "advance_tick neither creates nor destroys nodes, and tick increases" do
    check all(city <- CityGenerators.city()) do
      {next, _} = Calc.advance_tick(city)
      assert map_size(next.nodes) == map_size(city.nodes)
      assert Map.keys(next.nodes) |> Enum.sort() == Map.keys(city.nodes) |> Enum.sort()
      assert next.tick == city.tick + 1
    end
  end

  property "status is always consistent with health" do
    check all(city <- CityGenerators.city()) do
      {next, _} = Calc.advance_tick(city)

      for {_id, node} <- next.nodes do
        assert node.status == Node.status_for(node.health)
      end
    end
  end

  # A node regenerates only when every resource it consumes is fully satisfied;
  # otherwise it decays in proportion to the worst shortfall it is exposed to.
  # Consuming nothing counts as fully satisfied, hence the 1.0 seed.
  defp expected_health(node, stats) do
    worst =
      node.type
      |> Node.load()
      |> Enum.reduce(1.0, fn {resource, _amount}, acc ->
        min(acc, Map.fetch!(stats, resource).satisfaction)
      end)

    delta = if worst >= 1.0, do: @regen_per_tick, else: -(1.0 - worst) * @decay_per_tick

    (node.health + delta) |> max(@min_health) |> min(@max_health)
  end
end
