defmodule ArmchairMetropolist.Domain.Services.SimulationCalculator do
  @moduledoc """
  Pure domain calculations for advancing simulation state.

  The simulation is a deterministic function of the city map. One tick:

    1. `supply(r)` is the baseline capacity plus every node's *health-scaled*
       capacity for `r`, plus whatever balance `r` carried over from the
       previous tick (only money and waste use the generic carryover ledger;
       injuries, disease and crime are folded into their next-tick treatment demand).
       Labour is multiplied by the health-weighted park and school multipliers, then
       reduced by the city's existing injury and disease burden. With no housing,
       labour supply is 0.0 regardless of parks or schools. Existing crime similarly
       scales down commercial money capacity.
    2. `demand(r)` is every node's *full* load for `r` — deliberately
       **not** scaled by health. Broken infrastructure still draws resources.
       This asymmetry is what makes failures cascade rather than self-correct. Money
       loads are multiplied by inflation once the treasury crosses its threshold.
    3. Node upkeep is reserved, then scheduled opening-bond service and any
       commercial-bridge service are paid from the remaining balance. Current-tick
       income can service debt.
    4. Power, water, waste disposal and labour shortfalls are bought from the
       external market at its inflation-adjusted unit price. Only treasury carried into the
       tick is spendable, after reserving upkeep and debt service. If it cannot cover
       every shortfall, the same fraction of each is bought; traffic is never
       purchasable. Each unit of imported labour adds one unit of commuter
       traffic demand for that tick.
    5. `satisfaction(r)` is `min(1.0, available / demand)`, or `1.0` when
       nothing demands the resource, where `available` is supply plus the
       carried balance and purchases. **Not** floored at zero: a large enough
       unfunded backlog drives this negative.
    6. Each node looks at the satisfaction of only the resources it consumes
       and takes the worst of them.
    7. A fully supplied node regenerates `+1.0` health; a starved one loses
       `(1 - worst) * 6.0`.
    8. Health is clamped to `0.0..100.0` and status is re-derived from it.
    9. The tick counter advances by one.
   10. The returned delta holds only those nodes whose display signature
       (`{round(health), status}`) actually changed, so sub-pixel health
       movement does not push a full-grid diff to consumers.
   11. Money's surplus persists after debt service and market spending.
   12. Waste's *deficit* persists, as the mirror of that: the `waste_stock`
       balance becomes the tick's waste `deficit`, so unprocessed waste adds to
       the next tick's load and drains at `capacity - emissions`. Because the
       stock enters through `carried/2` negated, a backlog drives `satisfaction`
       below zero and health decay past `@decay_per_tick` — which is therefore a
       coefficient, not a maximum.
   13. Traffic's healthy threshold falls linearly from 100% of available capacity at
       zero utilization to 80% at full utilization. Demand above that moving threshold
       adds injuries. Disease outbreaks begin every 49 ticks with one residential block,
       then arrive three ticks sooner for each additional block down to a 10-tick interval. Each
       outbreak is also proportional to the number of residential blocks. The
       untreated remainder after health-scaled hospital capacity becomes the next
       tick's injury and disease stocks.
   14. Labour supply more than ten above demand creates crime. The untreated remainder
       after health-scaled police-station and school capacity becomes the next crime stock;
       that stock suppresses commercial income on the following tick.
   15. A running city with more than 1,000 in its treasury pays a gradually rising
       multiplier on construction, demolition, upkeep and imports, capped at 1.7x. Fixed
       bond principal and debt-service schedules are not repriced.

  Resource statistics are computed **once from the pre-tick map** and applied
  to every node, so within a single tick all nodes see identical city-wide
  conditions and the outcome does not depend on map iteration order.
  """

  alias ArmchairMetropolist.Domain.Entities.CityMap
  alias ArmchairMetropolist.Domain.Entities.MunicipalBond
  alias ArmchairMetropolist.Domain.Entities.Node
  alias ArmchairMetropolist.Domain.Entities.SimulationMetrics

  # No free power or workers: both come from local buildings or treasury-funded imports.
  # No free income either: money has no baseline, which is what forces commercial to be
  # built once the capacity and load tables arrive.
  #
  # Despite its name, this is not one of those tables: `Node`'s `@capacity_table` is the
  # health-scaled side of a node's ledger, while this belongs to no node and is never
  # scaled by anything.
  @baseline_capacity %{
    power: 0.0,
    water: 30.0,
    waste: 40.0,
    traffic: 30.0,
    injuries: 0.0,
    disease: 0.0,
    crime: 0.0,
    labour: 0.0,
    money: 0.0
  }
  @resources Map.keys(@baseline_capacity)
  @no_resources Map.new(@resources, fn resource -> {resource, 0.0} end)

  # The resources with a balance that survives the tick boundary — not always the same
  # side of it. Money is a treasury: its *unspent supply* carries forward as an asset.
  # Waste is the mirror: its *unmet demand* carries forward as a liability, which is why
  # `carried/2` negates it. Traffic does not accumulate: a landfill persists, a jam clears.
  @carryover [:money, :waste]

  # An external market backstops shortages without becoming another resource. Traffic is
  # absent deliberately: congestion cannot be imported away. Prices also define the
  # eligible set, so eligibility and cost cannot drift apart.
  @market_prices %{power: 1.0, water: 1.0, waste: 1.0, labour: 1.0}

  # Imported workers commute from outside the city. The traffic is a current-tick load,
  # not a stock: like every other jam it clears at the tick boundary. One-to-one keeps
  # the unit legible and roughly matches housing's 6 traffic for 5 local workers.
  @imported_labour_traffic_per_unit 1.0

  # Congestion becomes progressively less safe as the network fills. The healthy share
  # of available capacity slides linearly from 100% at zero utilization to 80% at full
  # utilization, then stays at 80% beyond capacity. Every ten trips above that moving
  # threshold add one injury to the stock for treatment.
  @initial_healthy_traffic_ratio 1.0
  @minimum_healthy_traffic_ratio 0.8
  @injuries_per_excess_traffic 0.1

  # Outbreaks are deterministic so a saved city resumes the same simulation and tests
  # can reason about exact ticks. One home retains a forgiving 49-tick opening cadence;
  # every additional home shortens it by three ticks until the 10-tick floor. Each
  # residential block also contributes two cases, so denser cities face both more frequent
  # and larger outbreaks.
  @base_disease_outbreak_interval 49
  @disease_outbreak_interval_step 3
  @minimum_disease_outbreak_interval 10
  @disease_per_residential 2.0

  # Ten untreated cases across one effective residential block suppress all five of
  # its workers. The ratio makes the same city-wide burden gentler as housing grows,
  # while still applying one shared multiplier to every residential block.
  @health_burden_tolerance_per_housing 10.0

  # A modest labour reserve is harmless; beyond it, workers left without productive work
  # create a persistent crime burden. Five excess workers create one crime per tick. Crime
  # then suppresses commercial income on the same stock-per-effective-block basis that
  # injuries and disease use for housing labour.
  @crime_free_excess_labour 10.0
  @crime_per_excess_labour 0.2
  @crime_burden_tolerance_per_commercial 20.0

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

  # Schools multiply the same housing labour pool as parks, but serve a broader catchment:
  # the bonus caps at one effective school per four effective homes. Below the cap, one
  # healthy school adds the same five gross workers as one healthy park; its higher build
  # and operating costs pay for the additional crime reduction it provides.
  @education_per_housing 1.0
  @max_education_ratio 0.25

  # Inflation is dormant in ordinary cities. Above 1,000 in the treasury, every additional
  # 1,000 raises variable costs by 10%, up to a 1.7x ceiling. The multiplier is derived from
  # the pre-tick balance, so it rises and falls gradually with the city's accumulated cash
  # rather than becoming another independently drifting stock.
  @inflation_threshold 1_000.0
  @inflation_per_money 0.0001
  @max_inflation_multiplier 1.7

  # How far ahead `rescue_window/3` will project before giving up and reporting `nil`.
  #
  # A bound on cost, not a judgement about the player: an insolvent city 200 ticks from
  # trouble shows no countdown rather than "200 ticks", which costs nothing worth having —
  # the figure only matters in the range where acting matters. Measured, the full horizon
  # costs 0.46 ms on 12 nodes, 2.1 ms on 50 and 37.6 ms on a full 1,200-node grid, and it is
  # only paid while the city is insolvent.
  @runway_horizon 60

  # The bridge quote protects more than the instant it is clicked. Six ticks is long
  # enough for the player to read the updated treasury, select commercial and place it,
  # while keeping this a small construction bridge rather than a second opening issue.
  @commercial_bridge_runway_ticks 6

  # A projection balance large enough that the quoted city's existing expenses cannot
  # hit the zero floor during six ticks. The difference between this seed and the
  # projected balance is therefore the real cash outflow, which can be added to the
  # construction cost without losing expenses that occur after an empty treasury would
  # otherwise clamp to zero.
  @commercial_bridge_projection_balance 1_000_000.0

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

  @doc "The money price of one externally purchased unit, by eligible resource."
  @spec market_prices() :: %{Node.resource() => float()}
  def market_prices, do: @market_prices

  @doc "The current price multiplier caused by a treasury above the inflation threshold."
  @spec inflation_multiplier(CityMap.t()) :: float()
  def inflation_multiplier(%CityMap{
        municipal_bond: %MunicipalBond{original_principal: principal, started_at_tick: nil}
      })
      when principal > 0.0,
      do: 1.0

  def inflation_multiplier(%CityMap{money: money}) do
    (1.0 + max(0.0, money - @inflation_threshold) * @inflation_per_money)
    |> min(@max_inflation_multiplier)
  end

  @doc "The whole-money construction charge at the city's current inflation level."
  @spec construction_cost(CityMap.t(), Node.node_type()) :: float()
  def construction_cost(city_map, type) do
    inflated_charge(Node.construction_cost(type), inflation_multiplier(city_map))
  end

  @doc "The whole-money demolition charge at the city's current inflation level."
  @spec demolition_cost(CityMap.t()) :: float()
  def demolition_cost(city_map) do
    inflated_charge(Node.demolition_cost(), inflation_multiplier(city_map))
  end

  @doc "External-market prices at the city's current inflation level."
  @spec market_prices(CityMap.t()) :: %{Node.resource() => float()}
  def market_prices(city_map) do
    multiplier = inflation_multiplier(city_map)
    Map.new(@market_prices, fn {resource, price} -> {resource, price * multiplier} end)
  end

  @doc "Treasury level above which inflation begins."
  @spec inflation_threshold() :: float()
  def inflation_threshold, do: @inflation_threshold

  @doc "Excess labour the city can absorb before crime begins accumulating."
  @spec crime_free_excess_labour() :: float()
  def crime_free_excess_labour, do: @crime_free_excess_labour

  @doc "Crime created per worker beyond the free excess-labour allowance."
  @spec crime_per_excess_labour() :: float()
  def crime_per_excess_labour, do: @crime_per_excess_labour

  @doc "Crime burden per effective commercial block that suppresses all commercial income."
  @spec crime_burden_tolerance_per_commercial() :: float()
  def crime_burden_tolerance_per_commercial, do: @crime_burden_tolerance_per_commercial

  @doc "Traffic demand added by one externally purchased unit of labour."
  @spec imported_labour_traffic_per_unit() :: float()
  def imported_labour_traffic_per_unit, do: @imported_labour_traffic_per_unit

  @doc "Healthy share of capacity at zero traffic utilization."
  @spec initial_healthy_traffic_ratio() :: float()
  def initial_healthy_traffic_ratio, do: @initial_healthy_traffic_ratio

  @doc "Lowest healthy share of capacity, reached at full traffic utilization."
  @spec minimum_healthy_traffic_ratio() :: float()
  def minimum_healthy_traffic_ratio, do: @minimum_healthy_traffic_ratio

  @doc "Healthy share of available capacity at the given traffic demand and capacity."
  @spec healthy_traffic_ratio(number(), number()) :: float()
  def healthy_traffic_ratio(demanded, capacity) do
    utilization =
      cond do
        demanded <= 0.0 -> 0.0
        capacity <= 0.0 -> 1.0
        true -> (demanded / capacity) |> max(0.0) |> min(1.0)
      end

    range = @initial_healthy_traffic_ratio - @minimum_healthy_traffic_ratio
    @initial_healthy_traffic_ratio - range * utilization
  end

  @doc "Number of ticks between deterministic disease outbreaks at the given housing count."
  @spec disease_outbreak_interval(non_neg_integer()) :: pos_integer()
  def disease_outbreak_interval(residential_count) do
    reduction = max(residential_count - 1, 0) * @disease_outbreak_interval_step

    max(@minimum_disease_outbreak_interval, @base_disease_outbreak_interval - reduction)
  end

  @doc "Injuries added per unit of traffic above the healthy threshold."
  @spec injuries_per_excess_traffic() :: float()
  def injuries_per_excess_traffic, do: @injuries_per_excess_traffic

  @doc "Disease cases added per residential block during an outbreak."
  @spec disease_per_residential() :: float()
  def disease_per_residential, do: @disease_per_residential

  @doc "Untreated cases per effective residential block that suppress all local labour."
  @spec health_burden_tolerance_per_housing() :: float()
  def health_burden_tolerance_per_housing, do: @health_burden_tolerance_per_housing

  @doc """
  Supply, purchases, demand, deficit and satisfaction for every resource in the city.

  Always returns an entry for all nine resources, even on an empty map. A node's
  capacity is scaled by that node's health; load is not scaled at all. The free
  baseline folded into `supplied` is scaled by nothing — it belongs to no node. Market
  capacity is reported separately as `purchased`.
  """
  @spec resource_stats(CityMap.t()) :: %{Node.resource() => SimulationMetrics.resource_stats()}
  def resource_stats(city_map), do: tick_plan(city_map).resources

  defp tick_plan(city_map), do: tick_plan(city_map, inflation_multiplier(city_map))

  defp tick_plan(city_map, inflation_multiplier) do
    nodes = CityMap.nodes(city_map)
    health_labour_multiplier = health_labour_multiplier(city_map, nodes)
    education_multiplier = education_multiplier(nodes)
    crime_money_multiplier = crime_money_multiplier(city_map, nodes)

    supply =
      total_supply(
        nodes,
        health_labour_multiplier,
        education_multiplier,
        crime_money_multiplier
      )

    demand = total_demand(nodes, inflation_multiplier)

    raw_stats =
      Map.new(@resources, fn resource ->
        supplied = Map.fetch!(supply, resource)
        carried = carried(city_map, resource)
        demanded = Map.fetch!(demand, resource)

        {resource,
         %{
           supplied: supplied,
           carried: carried,
           purchased: 0.0,
           demanded: demanded,
           deficit: max(0.0, demanded - supplied - carried),
           satisfaction: satisfaction(supplied + carried, demanded),
           # Same ratio, minus `carried`: the per-tick economy, ignoring any treasury
           # covering for it. Purchases are a current-tick flow, so the final value below
           # includes them on the supplied side.
           flow_satisfaction: satisfaction(supplied, demanded)
         }}
      end)

    cash_after_upkeep = raw_stats |> Map.fetch!(:money) |> new_balance()

    opening_service =
      MunicipalBond.service(city_map.municipal_bond, city_map.tick, cash_after_upkeep)

    cash_after_opening_bond = max(0.0, cash_after_upkeep - opening_service.payment)

    commercial_service =
      MunicipalBond.service(city_map.commercial_bond, city_map.tick, cash_after_opening_bond)

    cash_after_upkeep_and_bond =
      max(0.0, cash_after_opening_bond - commercial_service.payment)

    # Current-tick income can service the bond, but only treasury carried into the tick
    # can fund imports. The second bound reserves both node upkeep and debt first.
    purchase_budget = min(city_map.money, cash_after_upkeep_and_bond)
    purchases = market_purchases(raw_stats, purchase_budget, inflation_multiplier)
    raw_stats = add_imported_labour_traffic(raw_stats, purchases)
    raw_stats = add_health_burden_demand(raw_stats, city_map)
    raw_stats = add_crime_burden_demand(raw_stats, city_map, purchases)

    resources =
      Map.new(raw_stats, fn {resource, stats} ->
        purchased = Map.get(purchases, resource, 0.0)
        available = stats.supplied + stats.carried + purchased

        {resource,
         %{
           stats
           | purchased: purchased,
             deficit: max(0.0, stats.demanded - available),
             satisfaction: satisfaction(available, stats.demanded),
             flow_satisfaction: satisfaction(stats.supplied + purchased, stats.demanded)
         }}
      end)

    %{
      resources: resources,
      next_bond: opening_service.bond,
      next_commercial_bond: commercial_service.bond,
      bond_quote: MunicipalBond.quote(city_map.municipal_bond, city_map.tick),
      commercial_bond_quote: MunicipalBond.quote(city_map.commercial_bond, city_map.tick),
      bond_payment: opening_service.payment + commercial_service.payment,
      cash_after_upkeep_and_bond: cash_after_upkeep_and_bond,
      market_spend: market_spend(resources, inflation_multiplier)
    }
  end

  @doc """
  Advance the city by one tick.

  Returns the new city map and a delta map of only the nodes whose display
  signature changed.
  """
  @spec advance_tick(CityMap.t()) :: {CityMap.t(), delta()}
  def advance_tick(city_map) do
    plan = tick_plan(city_map)
    nodes = CityMap.nodes(city_map)

    if clock_paused?(city_map) or stalled?(nodes, plan.resources, city_map.waste_stock) do
      {city_map, %{}}
    else
      advance_tick(city_map, plan)
    end
  end

  # Split from `advance_tick/1` so the projection in `rescue_window/3` can compute
  # `resource_stats/1` once per step and spend it twice — on the stall check and on the
  # advance — rather than paying for it twice per projected tick.
  defp advance_tick(city_map, plan) do
    stats = plan.resources

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

    money = max(0.0, plan.cash_after_upkeep_and_bond - plan.market_spend)

    # The stock *is* the deficit — see `carried/2`. Read from the same pre-tick
    # `stats` every node saw, so the landfill and the health decay it caused
    # cannot disagree about the same tick.
    waste_stock = Map.fetch!(stats, :waste).deficit
    injury_stock = Map.fetch!(stats, :injuries).deficit
    disease_stock = Map.fetch!(stats, :disease).deficit
    crime_stock = Map.fetch!(stats, :crime).deficit

    {%{
       city_map
       | nodes: nodes,
         tick: city_map.tick + 1,
         money: money,
         waste_stock: waste_stock,
         injury_stock: injury_stock,
         disease_stock: disease_stock,
         crime_stock: crime_stock,
         municipal_bond: plan.next_bond,
         commercial_bond: plan.next_commercial_bond
     }, delta}
  end

  @doc """
  Build the aggregate metrics for the city in its current state.
  """
  @spec metrics(CityMap.t()) :: SimulationMetrics.t()
  def metrics(city_map) do
    nodes = CityMap.nodes(city_map)
    plan = tick_plan(city_map)
    stats = plan.resources
    stalled = stalled?(nodes, stats, city_map.waste_stock)
    operating = solvency(city_map, nodes, stats, stalled)
    financing = financing(city_map, nodes, plan.bond_quote, stalled)
    bond = if plan.bond_quote, do: Map.put(plan.bond_quote, :paused, stalled), else: nil

    commercial_bond =
      if plan.commercial_bond_quote,
        do: Map.put(plan.commercial_bond_quote, :paused, stalled),
        else: nil

    health_labour_multiplier = health_labour_multiplier(city_map, nodes)
    education_multiplier = education_multiplier(nodes)
    crime_money_multiplier = crime_money_multiplier(city_map, nodes)
    inflation_multiplier = inflation_multiplier(city_map)

    treasury_delta =
      if stalled or clock_paused?(city_map) do
        0.0
      else
        max(0.0, plan.cash_after_upkeep_and_bond - plan.market_spend) - city_map.money
      end

    derived =
      %{
        amenity: labour_multiplier(nodes),
        amenity_marginal_labour: marginal_amenity_labour(nodes, health_labour_multiplier),
        amenity_labour: placed_amenity_labour(nodes, health_labour_multiplier),
        education: education_multiplier,
        education_marginal_labour: marginal_education_labour(nodes, health_labour_multiplier),
        education_labour: placed_education_labour(nodes, health_labour_multiplier),
        health_labour_multiplier: health_labour_multiplier,
        crime_money_multiplier: crime_money_multiplier,
        inflation_multiplier: inflation_multiplier,
        construction_costs: Map.new(Node.types(), &{&1, construction_cost(city_map, &1)}),
        demolition_cost: demolition_cost(city_map),
        cheapest_action_cost:
          min(demolition_cost(city_map), construction_cost(city_map, cheapest_type())),
        market_spend: plan.market_spend,
        # The exact movement the next clock pulse will apply. Keeping this beside the
        # tick plan means the UI does not have to reconstruct debt priority, purchase
        # limits, or the two conditions that freeze the clock.
        treasury_delta: treasury_delta,
        imported_labour_traffic:
          Map.fetch!(stats, :labour).purchased * @imported_labour_traffic_per_unit,
        stalled: stalled,
        bond: bond,
        commercial_bond: commercial_bond,
        commercial_bond_offer: commercial_bond_offer(city_map, nodes)
      }
      |> Map.merge(operating)
      |> Map.merge(financing)

    SimulationMetrics.build(city_map, stats, derived)
  end

  # The bridge is a one-time escape hatch, not a general second bond market. A structurally
  # shrinking city needs enough commercial income to close the gap between rated income and
  # base upkeep. Once its treasury falls below the combined current cost of those blocks, the
  # bridge restores that construction budget plus a short operating runway. Health and
  # non-money supply do not gate the offer: those are exactly the pressures likely to be
  # present when emergency financing becomes useful. The server-side use case reads this
  # same value, so a forged click cannot borrow in any other state.
  defp commercial_bond_offer(city_map, nodes) do
    commercial_cost = construction_cost(city_map, :commercial)
    commercial_blocks = commercial_blocks_needed(nodes)
    construction_budget = commercial_blocks * commercial_cost

    eligible? =
      is_nil(city_map.commercial_bond) and not is_nil(city_map.municipal_bond) and
        not MunicipalBond.planning?(city_map.municipal_bond) and
        not MunicipalBond.defaulted?(city_map.municipal_bond) and nodes != [] and
        commercial_blocks > 0 and city_map.money < construction_budget

    if eligible? do
      projection_inflation = inflation_multiplier(city_map)

      projected =
        Enum.reduce(
          1..@commercial_bridge_runway_ticks,
          %{city_map | money: @commercial_bridge_projection_balance},
          fn
            _tick, current -> projected_tick(current, projection_inflation)
          end
        )

      projected_expenses =
        max(0.0, @commercial_bridge_projection_balance - projected.money)

      principal =
        max(0.0, construction_budget + projected_expenses - city_map.money)
        |> Float.ceil()

      %{
        principal: principal,
        construction_cost: commercial_cost,
        construction_budget: construction_budget,
        commercial_blocks: commercial_blocks,
        runway_ticks: @commercial_bridge_runway_ticks
      }
    end
  end

  defp commercial_blocks_needed(nodes) do
    gap = base_money_demand(nodes) - rated_money_capacity(nodes)

    if gap > 0.0 do
      gap
      |> Kernel./(money_net(:commercial))
      |> Float.ceil()
      |> trunc()
    else
      0
    end
  end

  defp projected_tick(city_map, inflation_multiplier) do
    plan = tick_plan(city_map, inflation_multiplier)
    nodes = CityMap.nodes(city_map)

    if clock_paused?(city_map) or stalled?(nodes, plan.resources, city_map.waste_stock),
      do: city_map,
      else: elem(advance_tick(city_map, plan), 0)
  end

  # The solvency group: the rated money ceiling, whether it falls short of upkeep, the
  # cheapest way out and how long the treasury can still buy it.
  #
  # Computed here rather than in `SimulationMetrics.build/3` for the same reason `stalled`
  # and the amenity figures are: `Domain.Entities` has `deps: []`, and the projection in
  # `rescue_window/4` needs `advance_tick/2`.
  #
  # The ceiling is the *rated* sum — every earner as though at full health — and that is the
  # load-bearing choice in the whole mechanic. Demand is never health-scaled and the node set
  # cannot change while the player cannot afford a command, so `supply <= ceiling < demand`
  # makes the balance strictly decreasing and the state provably terminal. Comparing the
  # health-scaled `supplied` instead would condemn any city whose earners are merely sick:
  # measured, a house beside a 5%-health shop and a park reads 2.5 against 3 of upkeep and
  # recovers to 9832 within 400 ticks.
  defp solvency(city_map, nodes, _stats, stalled) do
    ceiling = rated_money_capacity(nodes)
    # Inflation and crime can both recede without changing the node set, so neither can
    # prove permanent insolvency. Compare against the base upkeep floor here; current
    # inflated demand remains visible in the resource ledger and treasury projection.
    gap = base_money_demand(nodes) - ceiling

    if gap > 0.0 do
      escape = escape(city_map, nodes, gap)

      %{
        money_ceiling: ceiling,
        insolvent: true,
        escape: escape,
        rescue_window: rescue_window(city_map, escape_price(escape), stalled)
      }
    else
      %{money_ceiling: ceiling, insolvent: false, escape: nil, rescue_window: nil}
    end
  end

  defp financing(city_map, nodes, bond_quote, stalled) do
    locked = financing_locked?(city_map.money, nodes, bond_quote)

    if locked do
      escape = financing_escape(city_map, nodes, bond_quote)

      %{
        financing_locked: true,
        financing_escape: escape,
        financing_rescue_window: financing_rescue_window(city_map, escape_price(escape), stalled)
      }
    else
      %{
        financing_locked: false,
        financing_escape: nil,
        financing_rescue_window: nil
      }
    end
  end

  defp financing_locked?(_money, _nodes, nil), do: false

  defp financing_locked?(money, nodes, bond_quote) do
    if bond_quote.callable and bond_quote.redemption_amount > 0.0 do
      {interest_arrears, principal} = optimistic_redemption(money, bond_quote)
      surplus = rated_money_surplus(nodes)
      debt_remains? = interest_arrears > 0.0 or principal > 0.0

      debt_remains? and surplus <= MunicipalBond.interest_rate() * principal
    else
      false
    end
  end

  defp optimistic_redemption(money, bond_quote) do
    money = max(0.0, money)
    interest_paid = min(money, bond_quote.interest_arrears)
    after_interest = money - interest_paid

    {
      max(0.0, bond_quote.interest_arrears - interest_paid),
      max(0.0, bond_quote.outstanding_principal - after_interest)
    }
  end

  defp rated_money_surplus(nodes) do
    demand = base_money_demand(nodes)
    max(0.0, rated_money_capacity(nodes) - demand)
  end

  defp financing_escape(city_map, nodes, bond_quote) do
    placement_candidates =
      if not bond_quote.defaulted and length(nodes) < city_map.width * city_map.height do
        for type <- Node.types(),
            cost = construction_cost(city_map, type),
            city_map.money >= cost,
            candidate_recovers?(
              city_map.money - cost,
              [Node.new(0, 0, type) | nodes],
              bond_quote
            ),
            do: {:place, type, cost}
      else
        []
      end

    current_demolition_cost = demolition_cost(city_map)

    demolition_candidates =
      nodes
      |> Enum.map(& &1.type)
      |> Enum.uniq()
      |> Enum.filter(fn type ->
        city_map.money >= current_demolition_cost and
          candidate_recovers?(
            city_map.money - current_demolition_cost,
            remove_first_type(nodes, type),
            bond_quote
          )
      end)
      |> Enum.map(&{:demolish, &1, current_demolition_cost})

    case Enum.min_by(placement_candidates ++ demolition_candidates, &elem(&1, 2), fn -> nil end) do
      nil ->
        {:multiple, min(demolition_cost(city_map), construction_cost(city_map, cheapest_type()))}

      candidate ->
        candidate
    end
  end

  defp candidate_recovers?(money, nodes, bond_quote) do
    not financing_locked?(money, nodes, bond_quote)
  end

  defp remove_first_type(nodes, type) do
    {before, rest} = Enum.split_while(nodes, &(&1.type != type))

    case rest do
      [_removed | after_removed] -> before ++ after_removed
      [] -> nodes
    end
  end

  defp financing_rescue_window(_city_map, _price, true = _stalled), do: nil

  defp financing_rescue_window(city_map, price, _stalled) do
    Enum.reduce_while(0..@runway_horizon, city_map, fn elapsed, projected ->
      nodes = CityMap.nodes(projected)
      quote = MunicipalBond.quote(projected.municipal_bond, projected.tick)

      cond do
        projected.money < price ->
          {:halt, elapsed}

        not financing_locked?(projected.money, nodes, quote) ->
          {:halt, nil}

        elapsed == @runway_horizon or projected_stall?(projected) ->
          {:halt, nil}

        true ->
          {:cont, elem(advance_tick(projected), 0)}
      end
    end)
  end

  defp escape_price({:multiple, cost}), do: cost
  defp escape_price({_action, _type, cost}), do: cost

  # How many ticks the treasury can still afford `price`, by **projecting the city forward**
  # rather than dividing the balance by today's drain.
  #
  # The division is what this replaced, and it was wrong by a factor of two on a real city:
  # income is health-scaled, so a city whose earners are starving loses income while it
  # loses money, and the drain is the one term in that formula guaranteed to move. Measured
  # on one house, one shop and eleven parks at a treasury of 35 — the parks alone draw 198
  # water against a baseline of 30, so the shop starves — income fell 31 -> 21.96 while the
  # operating gap grew 2 -> 11.04 over five ticks. Market purchases made the escape
  # unaffordable after one tick where the division promised 12.
  #
  # Projecting is exact rather than merely tighter: `advance_tick/2` is pure and
  # deterministic, and the projection's premise — that the player does nothing — is
  # precisely what a countdown predicts. `price` holds still throughout, because it derives
  # from the gap between money demand and the *rated* ceiling, and both are count-based
  # rather than health-scaled, so neither moves while the node set does not.
  #
  # Measured cost, only paid while insolvent: 0.46 ms for the full horizon on 12 nodes,
  # 2.1 ms on 50, 37.6 ms on a pathological 1,200, against a 1,000 ms tick.
  defp rescue_window(_city_map, _price, true = _stalled), do: nil

  defp rescue_window(city_map, price, _stalled) do
    Enum.reduce_while(0..@runway_horizon, city_map, fn elapsed, projected ->
      cond do
        projected.money < price ->
          {:halt, elapsed}

        # A stalled city runs no tick, so its treasury stops falling here and the escape
        # stays affordable forever. Without this the projection would keep draining a
        # balance `CityEngine` has already frozen and report a deadline that never arrives.
        # This is the same defect as the clause above, one step further out.
        elapsed == @runway_horizon or projected_stall?(projected) ->
          {:halt, nil}

        true ->
          {:cont, elem(advance_tick(projected), 0)}
      end
    end)
  end

  defp projected_stall?(city_map) do
    nodes = CityMap.nodes(city_map)

    # The cheap necessary condition first: `stalled?/3` can only be true when every node is
    # on the floor, and computing `resource_stats/1` to discover otherwise would double the
    # cost of every projected tick in the common case.
    Enum.all?(nodes, &(&1.health == @min_health)) and
      stalled?(nodes, tick_plan(city_map).resources, city_map.waste_stock)
  end

  defp clock_paused?(%CityMap{municipal_bond: nil}), do: true

  defp clock_paused?(%CityMap{municipal_bond: bond}), do: MunicipalBond.planning?(bond)

  # Rated rather than effective: `Node.capacity/1`, not `Node.effective_capacity/1`.
  defp rated_money_capacity(nodes) do
    Enum.reduce(nodes, 0.0, fn node, acc ->
      acc + Map.get(Node.capacity(node.type), :money, 0.0)
    end)
  end

  # The cheapest single action that would close `gap`, so the banner can name one thing to
  # do rather than describing the problem.
  #
  # Placing one node of type `t` moves the gap by `-net(t)`; demolishing one moves it by
  # `+net(t)`, where `net(t)` is that type's money capacity minus its money load. One
  # formula covers both directions because demolishing removes the load *and* the capacity.
  #
  # Demolition is strictly cheaper than the cheapest construction — 10 against 15, a
  # property `node_test.exs` pins rather than assumes — so a placement can never outbid a
  # demolition. `min_by` is still the right shape: it is what makes the *placement* choice
  # (a house at 15 where +1 is enough, the shop at 40 where it is not) come out cheapest.
  defp escape(city_map, nodes, gap) do
    candidates = placements(city_map, nodes, gap) ++ demolitions(city_map, nodes, gap)

    case Enum.min_by(candidates, &elem(&1, 2), fn -> nil end) do
      nil ->
        {:multiple, min(demolition_cost(city_map), construction_cost(city_map, cheapest_type()))}

      action ->
        action
    end
  end

  # Only where a cell is free. `UseCases.ManageInfrastructure.place/4` refuses every occupied
  # coordinate, so on a full grid a priced placement is an instruction the player cannot
  # follow — the real route is a demolition and *then* a construction, which is two actions
  # and a different price. Without this the banner would name the shop on a grid with nowhere
  # to put it.
  defp placements(city_map, nodes, gap) do
    if length(nodes) < city_map.width * city_map.height do
      for type <- Node.types(),
          money_net(type) >= gap,
          do: {:place, type, construction_cost(city_map, type)}
    else
      []
    end
  end

  # Only types actually standing in the city — `escape/3` must not offer to demolish
  # something that is not there.
  defp demolitions(city_map, nodes, gap) do
    nodes
    |> Enum.map(& &1.type)
    |> Enum.uniq()
    |> Enum.filter(&(-money_net(&1) >= gap))
    |> Enum.map(&{:demolish, &1, demolition_cost(city_map)})
  end

  # Positive for a type that earns more than it costs to run, negative for one that is a net
  # drain. Reads both tables because a type can appear in either or both.
  defp money_net(type) do
    Map.get(Node.capacity(type), :money, 0.0) - Map.get(Node.load(type), :money, 0.0)
  end

  defp base_money_demand(nodes) do
    Enum.reduce(nodes, 0.0, fn node, total ->
      total + Map.get(Node.load(node.type), :money, 0.0)
    end)
  end

  defp cheapest_type do
    Enum.min_by(Node.types(), &Node.construction_cost/1)
  end

  defp inflated_charge(base, multiplier), do: Float.ceil(base * multiplier)

  # Baseline capacity plus health-scaled capacity from every node, with labour then
  # scaled by the park amenity.
  #
  # Applied here rather than in `resource_stats/1` so there is exactly one labour supply
  # figure: satisfaction, deficit, health decay, the deficit notification and the
  # Tightest line all read this and cannot disagree about it.
  defp total_supply(
         nodes,
         health_labour_multiplier,
         education_multiplier,
         crime_money_multiplier
       ) do
    supply =
      Enum.reduce(nodes, @baseline_capacity, fn node, acc ->
        node
        |> effective_capacity(crime_money_multiplier)
        |> Enum.reduce(acc, &add_resource/2)
      end)

    Map.update!(supply, :labour, fn labour ->
      labour * labour_multiplier(nodes) * education_multiplier * health_labour_multiplier
    end)
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

  # Effective schools per effective housing block, capped at one school per four homes.
  # Like parks, both sides are health-weighted so a neglected school loses its benefit.
  defp education_multiplier(nodes) do
    housing = effective_count(nodes, :residential)

    if housing > 0.0 do
      schools = effective_count(nodes, :school)

      1.0 +
        @education_per_housing * min(schools / housing, @max_education_ratio)
    else
      1.0
    end
  end

  # What one more park would add to labour supply, computed as an actual difference
  # rather than as the constant `L × k` (= 5.0) the algebra predicts. The two agree
  # everywhere except where the extra park takes the ratio across the cap, and there only
  # the difference is right.
  #
  # The probe park's coordinates are arbitrary. `total_supply/2` reduces over a list and
  # never reads position or identity, so a duplicate id cannot collide here — but this
  # list must not be put back into a CityMap.
  defp marginal_amenity_labour(nodes, health_labour_multiplier) do
    labour_supply([Node.new(0, 0, :park) | nodes], health_labour_multiplier) -
      labour_supply(nodes, health_labour_multiplier)
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
  # `total_supply/2` derives the multiplier from the nodes it is given, so the second term
  # is exactly the unamplified housing supply.
  defp placed_amenity_labour(nodes, health_labour_multiplier) do
    labour_supply(nodes, health_labour_multiplier) -
      labour_supply(Enum.reject(nodes, &(&1.type == :park)), health_labour_multiplier)
  end

  defp marginal_education_labour(nodes, health_labour_multiplier) do
    labour_supply([Node.new(0, 0, :school) | nodes], health_labour_multiplier) -
      labour_supply(nodes, health_labour_multiplier)
  end

  defp placed_education_labour(nodes, health_labour_multiplier) do
    labour_supply(nodes, health_labour_multiplier) -
      labour_supply(Enum.reject(nodes, &(&1.type == :school)), health_labour_multiplier)
  end

  defp labour_supply(nodes, health_labour_multiplier) do
    nodes
    |> total_supply(
      health_labour_multiplier,
      education_multiplier(nodes),
      1.0
    )
    |> Map.fetch!(:labour)
  end

  defp health_labour_multiplier(city_map, nodes) do
    housing = effective_count(nodes, :residential)

    if housing > 0.0 do
      burden = city_map.injury_stock + city_map.disease_stock
      max(0.0, 1.0 - burden / (housing * @health_burden_tolerance_per_housing))
    else
      1.0
    end
  end

  defp crime_money_multiplier(city_map, nodes) do
    commercial = effective_count(nodes, :commercial)

    if commercial > 0.0 do
      max(
        0.0,
        1.0 - city_map.crime_stock / (commercial * @crime_burden_tolerance_per_commercial)
      )
    else
      1.0
    end
  end

  defp effective_capacity(%{type: :commercial} = node, crime_money_multiplier) do
    Map.update!(Node.effective_capacity(node), :money, &(&1 * crime_money_multiplier))
  end

  defp effective_capacity(node, _crime_money_multiplier), do: Node.effective_capacity(node)

  # Counted by health rather than by node: a park at 40% health is 0.4 of a park.
  defp effective_count(nodes, type) do
    Enum.reduce(nodes, 0.0, fn
      %{type: ^type, health: health}, acc -> acc + health / 100.0
      _node, acc -> acc
    end)
  end

  # Full load from every node, regardless of that node's health.
  defp total_demand(nodes, inflation_multiplier) do
    Enum.reduce(nodes, @no_resources, fn node, acc ->
      node.type
      |> Node.load()
      |> inflate_money_load(inflation_multiplier)
      |> Enum.reduce(acc, &add_resource/2)
    end)
  end

  defp inflate_money_load(load, multiplier) do
    Map.update(load, :money, 0.0, &(&1 * multiplier))
  end

  # When the budget cannot cover every shortage, fund the same fraction of each one.
  # A sequential allocation would turn resource display order into a gameplay priority.
  defp market_purchases(stats, budget, inflation_multiplier) do
    required_cost =
      Enum.reduce(@market_prices, 0.0, fn {resource, price}, total ->
        total + Map.fetch!(stats, resource).deficit * price * inflation_multiplier
      end)

    funded_fraction =
      if required_cost > 0.0, do: min(1.0, budget / required_cost), else: 0.0

    Map.new(@market_prices, fn {resource, _price} ->
      {resource, Map.fetch!(stats, resource).deficit * funded_fraction}
    end)
  end

  defp market_spend(stats, inflation_multiplier) do
    Enum.reduce(@market_prices, 0.0, fn {resource, price}, total ->
      total + Map.fetch!(stats, resource).purchased * price * inflation_multiplier
    end)
  end

  defp add_imported_labour_traffic(stats, purchases) do
    commuter_traffic =
      Map.fetch!(purchases, :labour) * @imported_labour_traffic_per_unit

    Map.update!(stats, :traffic, fn traffic ->
      demanded = traffic.demanded + commuter_traffic
      available = traffic.supplied + traffic.carried

      %{
        traffic
        | demanded: demanded,
          deficit: max(0.0, demanded - available),
          satisfaction: satisfaction(available, demanded),
          flow_satisfaction: satisfaction(traffic.supplied, demanded)
      }
    end)
  end

  # Unlike waste, these stocks are presented as treatment demand rather than as
  # negative carried supply. That keeps a quiet tick with an existing stock visible
  # in the resource ledger instead of reading 0/0 and 100% supplied.
  defp add_health_burden_demand(stats, city_map) do
    traffic = Map.fetch!(stats, :traffic)
    traffic_capacity = traffic.supplied + traffic.carried
    healthy_traffic_ratio = healthy_traffic_ratio(traffic.demanded, traffic_capacity)

    injury_demand =
      city_map.injury_stock +
        max(0.0, traffic.demanded - traffic_capacity * healthy_traffic_ratio) *
          @injuries_per_excess_traffic

    disease_demand = city_map.disease_stock + disease_outbreak(city_map)

    stats
    |> put_stock_demand(:injuries, injury_demand)
    |> put_stock_demand(:disease, disease_demand)
  end

  defp add_crime_burden_demand(stats, city_map, purchases) do
    labour = Map.fetch!(stats, :labour)

    excess_labour =
      max(
        0.0,
        labour.supplied + Map.fetch!(purchases, :labour) - labour.demanded -
          @crime_free_excess_labour
      )

    crime_demand = city_map.crime_stock + excess_labour * @crime_per_excess_labour
    put_stock_demand(stats, :crime, crime_demand)
  end

  defp disease_outbreak(city_map) do
    residential_count =
      city_map.nodes
      |> Map.values()
      |> Enum.count(&(&1.type == :residential))

    interval = disease_outbreak_interval(residential_count)

    if residential_count > 0 and rem(city_map.tick + 1, interval) == 0 do
      residential_count * @disease_per_residential
    else
      0.0
    end
  end

  defp put_stock_demand(stats, resource, demanded) do
    Map.update!(stats, resource, fn resource_stats ->
      available = resource_stats.supplied

      %{
        resource_stats
        | demanded: demanded,
          deficit: max(0.0, demanded - available),
          satisfaction: satisfaction(available, demanded),
          flow_satisfaction: satisfaction(available, demanded)
      }
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

  # Floors the operating balance at zero before the separate bond-service step. An upkeep
  # that cannot be paid shows up as satisfaction below 1.0, while any remaining cash is
  # passed to `MunicipalBond.service/3` by `tick_plan/1`.
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

  # The city has reached a fixpoint: every node is on the floor and still short of
  # something, so `health_delta/1` is negative for all of them and the clamp holds
  # them at zero — and the landfill is not draining, so nothing can lift them off
  # it later either.
  #
  # That third condition is `deficit >= stock`, not `== stock`, and the comparator
  # is load-bearing. A *growing* landfill is a city getting monotonically worse and
  # is stalled; only a draining one has a route back. Testing `==` would call the
  # growing case unstalled, so a city drowning in waste would tick forever and
  # never satisfy `SimulationMetrics.game_over?/1`.
  #
  # Without the stock condition entirely, a backlogged stalled city freezes
  # permanently: `CityEngine.handle_info/2` runs no tick while `stalled` is true,
  # un-stalling needs the stock drained, and draining needs a tick.
  #
  # Both node clauses are load-bearing. Without the empty-list clause an untouched grid
  # is "stalled", because `Enum.all?/2` over nothing is true. Without the satisfaction
  # test, fully funded dead houses are called stalled the tick before market purchases
  # let them heal. With no free power, an unfunded dead power consumer really is stalled.
  #
  # Written per-node rather than against `avg_health`: health is clamped non-negative,
  # so "every node at 0.0" and "the average is 0.0 over a non-empty set" say the same
  # thing, and this form has no float sum in it to reason about.
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
