defmodule ArmchairMetropolist.Domain.Services.SimulationCalculator do
  @moduledoc """
  Pure domain calculations for advancing simulation state.

  The simulation is a deterministic function of the city map. One tick:

    1. `supply(r)` is the baseline capacity plus every node's *health-scaled*
       capacity for `r`, plus whatever balance `r` carried over from the
       previous tick (every resource but money carries nothing). Labour is then
       multiplied by the **park amenity** — `1 + k × min(parks/housing, cap)`,
       both sides health-weighted — so parks raise the workforce their housing
       supplies without producing labour themselves. With no housing the
       multiplier is 1.0 and labour supply is 0.0 regardless of parks.
    2. `demand(r)` is every node's *full* load for `r` — deliberately
       **not** scaled by health. Broken infrastructure still draws resources.
       This asymmetry is what makes failures cascade rather than self-correct.
    3. `satisfaction(r)` is `min(1.0, available / demand)`, or `1.0` when
       nothing demands the resource, where `available` is supply plus the
       carried balance. **Not** floored at zero: a large enough backlog drives
       this negative, which is what lets waste's stock (see step 10) decay
       health past `@decay_per_tick` rather than at it.
    4. Each node looks at the satisfaction of only the resources it consumes
       and takes the worst of them.
    5. A fully supplied node regenerates `+1.0` health; a starved one loses
       `(1 - worst) * 6.0`.
    6. Health is clamped to `0.0..100.0` and status is re-derived from it.
    7. The tick counter advances by one.
    8. The returned delta holds only those nodes whose display signature
       (`{round(health), status}`) actually changed, so sub-pixel health
       movement does not push a full-grid diff to consumers.
    9. Money's surplus persists: the city map's `money` balance becomes
       `max(0.0, supplied + carried - demanded)`, a treasury rather than a
       per-tick flow.
   10. Waste's *deficit* persists, as the mirror of that: the `waste_stock`
       balance becomes the tick's waste `deficit`, so unprocessed waste adds to
       the next tick's load and drains at `capacity - emissions`. Because the
       stock enters through `carried/2` negated, a backlog drives `satisfaction`
       below zero and health decay past `@decay_per_tick` — which is therefore a
       coefficient, not a maximum.

  Resource statistics are computed **once from the pre-tick map** and applied
  to every node, so within a single tick all nodes see identical city-wide
  conditions and the outcome does not depend on map iteration order.
  """

  alias ArmchairMetropolist.Domain.Entities.CityMap
  alias ArmchairMetropolist.Domain.Entities.Node
  alias ArmchairMetropolist.Domain.Entities.SimulationMetrics

  # No free workers: labour comes only from housing, which is the point of the resource.
  # No free income either: money has no baseline, which is what forces commercial to be
  # built once the capacity and load tables arrive.
  #
  # Despite its name, this is not one of those tables: `Node`'s `@capacity_table` is the
  # health-scaled side of a node's ledger, while this belongs to no node and is never
  # scaled by anything.
  @baseline_capacity %{
    power: 40.0,
    water: 40.0,
    waste: 40.0,
    traffic: 40.0,
    labour: 0.0,
    money: 0.0
  }
  @resources Map.keys(@baseline_capacity)
  @no_resources Map.new(@resources, fn resource -> {resource, 0.0} end)

  # The resources whose unspent supply survives the tick boundary. Money is a
  # treasury: its surplus carries forward as an asset. Waste is the mirror — its
  # *deficit* carries forward as a liability, which is why `carried/2` negates it.
  # Traffic does not accumulate: a landfill persists, a jam clears.
  @carryover [:money, :waste]

  # The park amenity: parks per housing block multiply labour supply. Both values are
  # measured, not chosen — see docs/superpowers/specs/2026-08-05-park-amenity-design.md
  # §4.
  #
  # A park draws 1 labour of its own, so its net contribution is `L × k - 1`, where `L` is
  # residential's labour capacity of 5.0. `k = 1.0` is the value for two reasons. It
  # clears the measured threshold: at k = 0.5 the net is only +1.5 and the optimal city is
  # byte-identical to one with no amenity at all, so the mechanic would ship as a no-op.
  # And it is the smallest such value keeping the gross bonus `L × k` a whole number —
  # k = 0.75 reaches the same optimum but makes it 3.75, which the legend's `signed/1`
  # would round to a figure the domain does not supply.
  #
  # The cap is the ratio past which more parks add nothing; it is inert in small cities and
  # binds gently in large ones.
  @amenity_per_housing 1.0
  @max_amenity_ratio 1.0

  @regen_per_tick 1.0
  @decay_per_tick 6.0
  @min_health 0.0
  @max_health 100.0

  @type delta :: %{optional(String.t()) => Node.t()}

  @doc """
  The city's free infrastructure-independent capacity, per resource.

  Every city starts able to support a small amount of development with no
  producers placed at all.
  """
  @spec baseline_capacity() :: %{Node.resource() => float()}
  def baseline_capacity, do: @baseline_capacity

  @doc """
  Supply, demand, deficit and satisfaction for every resource in the city.

  Always returns an entry for all six resources, even on an empty map. A node's
  capacity is scaled by that node's health; load is not scaled at all. The free
  baseline folded into `supplied` is scaled by nothing — it belongs to no node.
  """
  @spec resource_stats(CityMap.t()) :: %{Node.resource() => SimulationMetrics.resource_stats()}
  def resource_stats(city_map) do
    nodes = CityMap.nodes(city_map)
    supply = total_supply(nodes)
    demand = total_demand(nodes)

    Map.new(@resources, fn resource ->
      supplied = Map.fetch!(supply, resource)
      carried = carried(city_map, resource)
      demanded = Map.fetch!(demand, resource)
      available = supplied + carried

      stats = %{
        supplied: supplied,
        carried: carried,
        demanded: demanded,
        deficit: max(0.0, demanded - available),
        satisfaction: satisfaction(available, demanded),
        # Same ratio, minus `carried`: the per-tick economy, ignoring any treasury
        # covering for it. `worst_satisfaction/2` (health decay), the deficit
        # notification and `tightest_resource/1` all answer "what is damaging the
        # city right now", so they keep the balance-inclusive `satisfaction` above —
        # a deficit savings are covering must not decay anything or page anyone.
        # The legend's totals cell answers a different question, "is my per-tick
        # economy balanced", so it reads this field instead.
        flow_satisfaction: satisfaction(supplied, demanded)
      }

      {resource, stats}
    end)
  end

  @doc """
  Advance the city by one tick.

  Returns the new city map and a delta map of only the nodes whose display
  signature changed.
  """
  @spec advance_tick(CityMap.t()) :: {CityMap.t(), delta()}
  def advance_tick(city_map) do
    stats = resource_stats(city_map)

    {nodes, delta} =
      Enum.reduce(city_map.nodes, {%{}, %{}}, fn {key, node}, {nodes, delta} ->
        advanced = advance_node(node, stats)

        delta =
          if Node.display_signature(node) == Node.display_signature(advanced) do
            delta
          else
            Map.put(delta, key, advanced)
          end

        {Map.put(nodes, key, advanced), delta}
      end)

    money = new_balance(Map.fetch!(stats, :money))

    # The stock *is* the deficit — see `carried/2`. Read from the same pre-tick
    # `stats` every node saw, so the landfill and the health decay it caused
    # cannot disagree about the same tick.
    waste_stock = Map.fetch!(stats, :waste).deficit

    {%{city_map | nodes: nodes, tick: city_map.tick + 1, money: money, waste_stock: waste_stock},
     delta}
  end

  @doc """
  Build the aggregate metrics for the city in its current state.
  """
  @spec metrics(CityMap.t()) :: SimulationMetrics.t()
  def metrics(city_map) do
    nodes = CityMap.nodes(city_map)
    stats = resource_stats(city_map)

    derived = %{
      amenity: labour_multiplier(nodes),
      amenity_marginal_labour: marginal_amenity_labour(nodes),
      amenity_labour: placed_amenity_labour(nodes),
      stalled: stalled?(nodes, stats, city_map.waste_stock)
    }

    SimulationMetrics.build(city_map, stats, derived)
  end

  # Baseline capacity plus health-scaled capacity from every node, with labour then
  # scaled by the park amenity.
  #
  # Applied here rather than in `resource_stats/1` so there is exactly one labour supply
  # figure: satisfaction, deficit, health decay, the deficit notification and the
  # Tightest line all read this and cannot disagree about it.
  defp total_supply(nodes) do
    supply =
      Enum.reduce(nodes, @baseline_capacity, fn node, acc ->
        Enum.reduce(Node.effective_capacity(node), acc, &add_resource/2)
      end)

    Map.update!(supply, :labour, &(&1 * labour_multiplier(nodes)))
  end

  # Effective parks per effective housing block, capped, scaled by
  # `@amenity_per_housing`. Health-weighted on both sides: a neglected park provides no
  # amenity, and a dying neighbourhood needs fewer parks to serve it. A count-based
  # ratio would let a dead park go on multiplying, making `park` the one type neglect
  # cannot punish.
  #
  # The `housing > 0.0` guard is load-bearing, not defensive. Erlang does not follow
  # IEEE 754 for float division, so `0.0 / 0.0` raises `ArithmeticError` rather than
  # yielding NaN — it is not enough that the result would be multiplied by a zero labour
  # supply, because the division happens first. An empty city and a city bulldozed to
  # nothing but parks both reach this on an ordinary tick.
  defp labour_multiplier(nodes) do
    housing = effective_count(nodes, :residential)

    if housing > 0.0 do
      parks = effective_count(nodes, :park)
      1.0 + @amenity_per_housing * min(parks / housing, @max_amenity_ratio)
    else
      1.0
    end
  end

  # What one more park would add to labour supply, computed as an actual difference
  # rather than as the constant `L × k` (= 5.0) the algebra predicts. The two agree
  # everywhere except where the extra park takes the ratio across the cap, and there only
  # the difference is right.
  #
  # The probe park's coordinates are arbitrary. `total_supply/1` reduces over a list and
  # never reads position or identity, so a duplicate id cannot collide here — but this
  # list must not be put back into a CityMap.
  defp marginal_amenity_labour(nodes) do
    labour_supply([Node.new(0, 0, :park) | nodes]) - labour_supply(nodes)
  end

  # What the parks *already placed* are contributing to labour supply — the counterpart to
  # `marginal_amenity_labour/1`, which asks about one more. The legend stacks both, and
  # conflating them is what made park's labour total report a bare staffing draw.
  #
  # Computed as a real difference against the same city with its parks removed rather than
  # from the algebra, for the same reason as the marginal figure: below the cap this equals
  # `L × k × parks`, but at the cap it equals `L × k × housing`, and only the difference is
  # right on both sides of that boundary without a case split.
  #
  # Removing the parks changes nothing else about labour. Parks produce no labour, and
  # `total_supply/1` derives the multiplier from the nodes it is given, so the second term
  # is exactly the unamplified housing supply.
  defp placed_amenity_labour(nodes) do
    labour_supply(nodes) - labour_supply(Enum.reject(nodes, &(&1.type == :park)))
  end

  defp labour_supply(nodes), do: nodes |> total_supply() |> Map.fetch!(:labour)

  # Counted by health rather than by node: a park at 40% health is 0.4 of a park.
  defp effective_count(nodes, type) do
    Enum.reduce(nodes, 0.0, fn
      %{type: ^type, health: health}, acc -> acc + health / 100.0
      _node, acc -> acc
    end)
  end

  # Full load from every node, regardless of that node's health.
  defp total_demand(nodes) do
    Enum.reduce(nodes, @no_resources, fn node, acc ->
      node.type
      |> Node.load()
      |> Enum.reduce(acc, &add_resource/2)
    end)
  end

  defp add_resource({resource, amount}, acc) do
    Map.update(acc, resource, amount, &(&1 + amount))
  end

  # The guard stays on @carryover so the list remains the single place a reader
  # looks to learn which resources carry a balance; the sign lives in the clauses
  # below it.
  #
  # Waste's balance is returned **negated**, and that one sign is the whole
  # mechanic. It makes `available = supplied + carried` read `supplied - stock`,
  # and therefore makes `deficit = max(0.0, demanded - available)` equal
  # `demanded - supplied + stock` — exactly the next tick's stock, with no second
  # formula to keep in step.
  defp carried(city_map, resource) when resource in @carryover,
    do: carried_balance(city_map, resource)

  defp carried(_city_map, _resource), do: 0.0

  defp carried_balance(city_map, :money), do: city_map.money
  defp carried_balance(city_map, :waste), do: -city_map.waste_stock

  # Floors at zero: debt is not modelled. An upkeep that cannot be paid shows up
  # as satisfaction below 1.0, which the existing decay path already handles.
  defp new_balance(%{supplied: supplied, carried: carried, demanded: demanded}) do
    max(0.0, supplied + carried - demanded)
  end

  defp satisfaction(_supplied, demanded) when demanded == 0.0, do: 1.0
  defp satisfaction(supplied, demanded), do: min(1.0, supplied / demanded)

  defp advance_node(node, stats) do
    health = clamp(node.health + health_delta(worst_satisfaction(node, stats)))
    %{node | health: health, status: Node.status_for(health)}
  end

  # Only the resources this node actually consumes constrain it. Starting the
  # reduction at 1.0 also covers a node type that consumes nothing.
  defp worst_satisfaction(node, stats) do
    node.type
    |> Node.load()
    |> Enum.reduce(1.0, fn {resource, _amount}, acc ->
      min(acc, Map.fetch!(stats, resource).satisfaction)
    end)
  end

  # The city has reached a fixpoint in health: every node is on the floor and every
  # node is still short of something, so `health_delta/1` is negative for all of them,
  # the clamp holds them at zero, and demand — which is not health-scaled — does not
  # move. The next tick is therefore identical in every node.
  #
  # Both node clauses are load-bearing. Without the empty-list clause an untouched grid
  # is "stalled", because `Enum.all?/2` over nothing is true. Without the satisfaction
  # test, one or two dead houses are called stalled the tick before they heal: they
  # draw 30 power against the free baseline of 40, so they are fully supplied at zero
  # health and regenerate. The cliff is `15n <= 40`.
  #
  # Written per-node rather than against `avg_health`: health is clamped non-negative,
  # so "every node at 0.0" and "the average is 0.0 over a non-empty set" say the same
  # thing, and this form has no float sum in it to reason about.
  #
  # The third argument closes a route the node check alone cannot see: a stalled node
  # fixpoint says no *node* can recover on its own, but a draining landfill means the
  # *city* still can, one tick from now, once the stock clears. `>=` and not `==`: a
  # growing landfill (`deficit > stock`) is getting monotonically worse and stays
  # stalled; only a draining one (`deficit < stock`) has a route back. The engine
  # skips ticks entirely while stalled, so calling a draining city stalled would freeze
  # the stock forever and the city could never satisfy `SimulationMetrics.game_over?/1`.
  defp stalled?([], _stats, _stock), do: false

  defp stalled?(nodes, stats, stock) do
    Enum.all?(nodes, fn node ->
      node.health == @min_health and worst_satisfaction(node, stats) < 1.0
    end) and Map.fetch!(stats, :waste).deficit >= stock
  end

  defp health_delta(worst) when worst >= 1.0, do: @regen_per_tick
  defp health_delta(worst), do: -(1.0 - worst) * @decay_per_tick

  defp clamp(health), do: health |> max(@min_health) |> min(@max_health)
end
