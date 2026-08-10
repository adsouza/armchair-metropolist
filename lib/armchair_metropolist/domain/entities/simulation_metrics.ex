defmodule ArmchairMetropolist.Domain.Entities.SimulationMetrics do
  @moduledoc "Aggregate supply/demand and health figures for one tick."

  alias ArmchairMetropolist.Domain.Entities.CityMap
  alias ArmchairMetropolist.Domain.Entities.Node

  @type bond_summary :: %{
          legacy: boolean(),
          original_principal: float(),
          outstanding_principal: float(),
          interest_arrears: float(),
          principal_arrears: float(),
          started: boolean(),
          redemption_amount: float(),
          opening_period_remaining: non_neg_integer(),
          call_protection_remaining: non_neg_integer(),
          callable: boolean(),
          maturity_remaining: non_neg_integer(),
          next_interest: float(),
          next_principal: float(),
          next_payment: float(),
          defaulted: boolean(),
          paused: boolean()
        }

  @type commercial_bond_offer :: %{
          principal: float(),
          construction_cost: float(),
          runway_ticks: pos_integer()
        }

  @typedoc """
  Two satisfaction figures, on two different bases. `satisfaction` is computed
  over `supplied + carried + purchased` — the balance-inclusive figure that drives health
  decay, the deficit notification and the *Tightest* line, all of which answer
  "what is damaging the city right now". `flow_satisfaction` is the same ratio
  computed over `supplied + purchased`, ignoring `carried` entirely — the figure the
  legend's totals cell renders, answering "is my per-tick economy balanced".
  `purchased` records external-market capacity added for this tick. Most resources
  carry nothing (`carried: 0.0`), so the two satisfaction figures agree. Money and
  waste are the two that do, and they diverge in opposite directions: money's
  carried balance is a treasury, so `satisfaction` never sits *below*
  `flow_satisfaction` — savings can only cover a flow deficit, never worsen one.
  Waste's carried balance is a backlog, entered negated (see `carried/2`), so
  `satisfaction` never sits *above* `flow_satisfaction` — a landfill can only
  make this tick read worse than its own flow, never better. Neither is a
  strict inequality: an empty balance, or both simply clamped at 1.0, leaves
  the two equal.
  """
  @type resource_stats :: %{
          supplied: float(),
          carried: float(),
          purchased: float(),
          demanded: float(),
          deficit: float(),
          satisfaction: float(),
          flow_satisfaction: float()
        }

  @typedoc """
  One type's contribution. A key is present in the inner maps only where that node
  type's base tables mention the resource, so a missing key means "does not interact"
  while a present `0.0` means "nets to zero" — the legend renders those differently.
  """
  @type type_stats :: %{
          count: non_neg_integer(),
          rated_capacity: %{Node.resource() => float()},
          actual_capacity: %{Node.resource() => float()},
          load: %{Node.resource() => float()}
        }

  @type t :: %__MODULE__{
          tick: non_neg_integer(),
          resources: %{optional(atom()) => resource_stats()},
          node_count: non_neg_integer(),
          avg_health: float(),
          offline_count: non_neg_integer(),
          by_type: %{Node.node_type() => type_stats()},
          money: float(),
          waste_stock: float(),
          injury_stock: float(),
          disease_stock: float(),
          crime_stock: float(),
          market_spend: float(),
          treasury_delta: float(),
          imported_labour_traffic: float(),
          amenity: float(),
          amenity_marginal_labour: float(),
          amenity_labour: float(),
          education: float(),
          education_marginal_labour: float(),
          education_labour: float(),
          health_labour_multiplier: float(),
          crime_money_multiplier: float(),
          inflation_multiplier: float(),
          construction_costs: %{Node.node_type() => float()},
          demolition_cost: float(),
          cheapest_action_cost: float(),
          housing_alive: boolean(),
          bankrupt: boolean(),
          money_ceiling: float(),
          insolvent: boolean(),
          escape: escape() | nil,
          rescue_window: non_neg_integer() | nil,
          bond: bond_summary() | nil,
          commercial_bond: bond_summary() | nil,
          commercial_bond_offer: commercial_bond_offer() | nil,
          financing_locked: boolean(),
          financing_escape: escape() | nil,
          financing_rescue_window: non_neg_integer() | nil,
          stalled: boolean()
        }

  @typedoc """
  The cheapest single action that would end the city's insolvency, with its price.

  `:multiple` means no single action closes the gap — the copy must say so rather than
  naming an action that would not work — and carries the price of *starting*, not of
  finishing. `nil` on a solvent city, where there is nothing to escape.
  """
  @type escape ::
          {:place, Node.node_type(), float()}
          | {:demolish, Node.node_type(), float()}
          | {:multiple, float()}

  # How close the rescue window has to get before the player is told. Twelve ticks, which at
  # the configured `:tick_interval_ms` of 1,000 is twelve seconds to read the banner and
  # click once.
  #
  # A midpoint, not an edge. The binding constraint is stage 6 of the opening sequence in
  # `docs/PLAYING.md`, where the treasury holds 180 against a 40-cost shop and drains 9 a
  # tick: measured, that city's window is 16 ticks, so anything up to 15 keeps the tutorial
  # quiet and 16 warns during it. 12 leaves four ticks of margin. `playing_guide_test` asserts
  # no stage of that generated sequence warns, so a balance patch which moves the sequence
  # fails the build rather than quietly alarming players mid-tutorial.
  @reaction_ticks 12

  # A city with no parks has no amenity, so the identity multiplier and zero labour from it
  # are the correct values rather than filler, and a city with no nodes is not stalled. The
  # default exists because `build/2` has a dozen call sites in tests; the one production
  # caller, `Domain.Services.SimulationCalculator.metrics/1`, always passes real figures,
  # and a test on that wiring is what stops this default reaching a player.
  #
  # The solvency four default to a city that is in no trouble: nothing earned, nothing owed,
  # nothing to escape from. `insolvent: false` is the safe direction — the failure it causes
  # if it ever reached a player is a missing banner, whereas `true` would put "City locked"
  # on a healthy city.
  @default_derived %{
    amenity: 1.0,
    amenity_marginal_labour: 0.0,
    amenity_labour: 0.0,
    education: 1.0,
    education_marginal_labour: 0.0,
    education_labour: 0.0,
    health_labour_multiplier: 1.0,
    crime_money_multiplier: 1.0,
    inflation_multiplier: 1.0,
    construction_costs: Map.new(Node.types(), &{&1, Node.construction_cost(&1)}),
    demolition_cost: Node.demolition_cost(),
    cheapest_action_cost: Node.cheapest_action_cost(),
    market_spend: 0.0,
    treasury_delta: 0.0,
    imported_labour_traffic: 0.0,
    stalled: false,
    money_ceiling: 0.0,
    insolvent: false,
    escape: nil,
    rescue_window: nil,
    bond: nil,
    commercial_bond: nil,
    commercial_bond_offer: nil,
    financing_locked: false,
    financing_escape: nil,
    financing_rescue_window: nil
  }

  defstruct tick: 0,
            resources: %{},
            node_count: 0,
            avg_health: 0.0,
            offline_count: 0,
            by_type: %{},
            money: 0.0,
            waste_stock: 0.0,
            injury_stock: 0.0,
            disease_stock: 0.0,
            crime_stock: 0.0,
            market_spend: 0.0,
            treasury_delta: 0.0,
            imported_labour_traffic: 0.0,
            amenity: 1.0,
            amenity_marginal_labour: 0.0,
            amenity_labour: 0.0,
            education: 1.0,
            education_marginal_labour: 0.0,
            education_labour: 0.0,
            health_labour_multiplier: 1.0,
            crime_money_multiplier: 1.0,
            inflation_multiplier: 1.0,
            construction_costs: %{},
            demolition_cost: 10.0,
            cheapest_action_cost: 10.0,
            housing_alive: false,
            bankrupt: false,
            money_ceiling: 0.0,
            insolvent: false,
            escape: nil,
            rescue_window: nil,
            bond: nil,
            commercial_bond: nil,
            commercial_bond_offer: nil,
            financing_locked: false,
            financing_escape: nil,
            financing_rescue_window: nil,
            stalled: false

  @doc """
  Build a SimulationMetrics struct from a city map, resource statistics and the city's
  derived figures.

  `derived` carries `:amenity` (the park multiplier on labour supply),
  `:amenity_marginal_labour` (what one more park would add to it), `:amenity_labour`
  (what the *already placed* parks are contributing), `:health_labour_multiplier`
  (what remains after injuries and disease), the equivalent education figures for schools,
  the crime multiplier on commercial income, inflation and its live action prices, and
  `:stalled` (whether the city has reached a health fixpoint).

  It also carries the solvency four: `:money_ceiling` (what the city could earn with every
  earner at full health), `:insolvent` (whether upkeep exceeds that ceiling),
  `:escape` (the cheapest single action that would end the insolvency) and `:rescue_window`
  (how many ticks the treasury can still afford it). `:rescue_window` is the reason these
  travel this way rather than being derived here even though the first two look local: it is
  computed by projecting the city forward with `advance_tick/2`.

  `:market_spend` is the money those automatic purchases consume this tick,
  `:treasury_delta` is the exact balance movement the next live tick will apply, and
  `:imported_labour_traffic` is the commuter demand created by the labour portion.
  `:commercial_bond` is the live bridge-series quote, while
  `:commercial_bond_offer` is the one-time rescue quote when the city qualifies.

  These figures are computed by `Domain.Services.SimulationCalculator`, which this module
  cannot call — `Domain` has `deps: []` — so they arrive as an argument rather than being
  derived here. A partial map is a programming error; see the `Map.fetch!/2` calls below.
  """
  def build(city_map, resources, derived \\ @default_derived) do
    nodes = CityMap.nodes(city_map)
    node_count = length(nodes)

    avg_health = calculate_avg_health(nodes)
    offline_count = count_offline_nodes(nodes)

    %__MODULE__{
      tick: city_map.tick,
      resources: resources,
      node_count: node_count,
      avg_health: avg_health,
      offline_count: offline_count,
      by_type:
        build_by_type(
          nodes,
          Map.fetch!(derived, :health_labour_multiplier),
          Map.fetch!(derived, :crime_money_multiplier),
          Map.fetch!(derived, :inflation_multiplier)
        ),
      money: city_map.money,
      waste_stock: city_map.waste_stock,
      injury_stock: city_map.injury_stock,
      disease_stock: city_map.disease_stock,
      crime_stock: city_map.crime_stock,
      market_spend: Map.fetch!(derived, :market_spend),
      treasury_delta: Map.fetch!(derived, :treasury_delta),
      imported_labour_traffic: Map.fetch!(derived, :imported_labour_traffic),
      amenity: Map.fetch!(derived, :amenity),
      amenity_marginal_labour: Map.fetch!(derived, :amenity_marginal_labour),
      amenity_labour: Map.fetch!(derived, :amenity_labour),
      education: Map.fetch!(derived, :education),
      education_marginal_labour: Map.fetch!(derived, :education_marginal_labour),
      education_labour: Map.fetch!(derived, :education_labour),
      health_labour_multiplier: Map.fetch!(derived, :health_labour_multiplier),
      crime_money_multiplier: Map.fetch!(derived, :crime_money_multiplier),
      inflation_multiplier: Map.fetch!(derived, :inflation_multiplier),
      construction_costs: Map.fetch!(derived, :construction_costs),
      demolition_cost: Map.fetch!(derived, :demolition_cost),
      cheapest_action_cost: Map.fetch!(derived, :cheapest_action_cost),
      housing_alive: housing_alive?(nodes),
      # The live inflation-adjusted action floor, supplied by the calculator alongside
      # the prices the UI renders. Using the base `Node.cheapest_action_cost/0` here would
      # call a city bankrupt while it can no longer afford today's inflated demolition.
      bankrupt: city_map.money < Map.fetch!(derived, :cheapest_action_cost),
      money_ceiling: Map.fetch!(derived, :money_ceiling),
      insolvent: Map.fetch!(derived, :insolvent),
      escape: Map.fetch!(derived, :escape),
      rescue_window: Map.fetch!(derived, :rescue_window),
      bond: Map.fetch!(derived, :bond),
      commercial_bond: Map.fetch!(derived, :commercial_bond),
      commercial_bond_offer: Map.fetch!(derived, :commercial_bond_offer),
      financing_locked: Map.fetch!(derived, :financing_locked),
      financing_escape: Map.fetch!(derived, :financing_escape),
      financing_rescue_window: Map.fetch!(derived, :financing_rescue_window),
      stalled: Map.fetch!(derived, :stalled)
    }
  end

  @doc """
  Whether this city's treasury can never rise again and no financing escape remains — and
  so whether the player can never act again, since every infrastructure command has a price.

  `bankrupt` is necessary: while any command is affordable the player still has a move, and
  neither `stalled` nor `insolvent` is beyond help on its own. The commercial-bridge offer
  is also an action, so a qualifying healthy city is not game over even below the ordinary
  command floor. A stalled city holding money can be rescued by one demolition, which takes
  three dead houses back under the free baseline; an insolvent city holding money can buy
  the shop that ends the insolvency.

  Given bankruptcy, either of two conditions makes the treasury's floor permanent, and
  neither implies the other:

    * `stalled` — every block is on the floor, so production, which is health-scaled, is
      zero and the engine has stopped ticking. The *rated* ceiling may be far above upkeep
      the whole time: a dead shop is still rated +30.

    * `insolvent` — upkeep exceeds what the city could earn at full health, so the balance
      is strictly decreasing however healthy the city looks. Measured, one house at 100
      health beside one park holds that health for 2000 ticks while its treasury stays at
      zero, so `stalled` never fires and the old two-term predicate never fired either.

  Defined here, once, rather than composed at each call site: the template and
  `docs/PLAYING.md` both describe this state and must not be able to disagree about it.
  """
  @spec game_over?(t()) :: boolean()
  def game_over?(%__MODULE__{} = metrics),
    do:
      not opening_planning?(metrics) and metrics.bankrupt and
        is_nil(metrics.commercial_bond_offer) and
        (metrics.stalled or metrics.insolvent or metrics.financing_locked)

  @doc """
  Whether the city is insolvent and close enough to losing its escape to be told about it.

  Four terms, and each excludes a state that would make the countdown a lie:

    * `insolvent` — a solvent city's treasury is not on a one-way trip, so there is nothing
      to count down to. A city merely spending faster than it earns today recovers as its
      earners heal.

    * `not stalled` — **`insolvent` and `stalled` are not mutually exclusive.** A single dead
      water plant has a money ceiling of 0 against 5 of upkeep, so it is insolvent; with 50
      in the bank it is not bankrupt either. But `CityEngine` runs no tick while stalled, so
      that 50 never moves and a countdown in ticks describes something that will not happen.
      The stalled banner already says the true thing about such a city.

    * `not bankrupt` — past that point there is nothing left to warn about and
      `game_over?/1` has taken over. Keeping them disjoint is what lets the banner render
      exactly one thing.

    * a `rescue_window` inside `@reaction_ticks` — `nil` means the projection found no
      deadline within its horizon, which is the *good* case and must not be compared
      numerically.

  `@reaction_ticks` is 12, so at the configured 1,000 ms tick this is at least twelve
  seconds to read the banner and click once. "At least" is literal: `rescue_window` is
  projected with the real tick function rather than extrapolated from the current drain, so
  a city whose income is collapsing gets its warning earlier in treasury terms rather than
  later in time.
  """
  @spec warning?(t()) :: boolean()
  def warning?(%__MODULE__{insolvent: false}), do: false
  def warning?(%__MODULE__{stalled: true}), do: false
  def warning?(%__MODULE__{bankrupt: true}), do: false
  def warning?(%__MODULE__{rescue_window: nil}), do: false
  def warning?(%__MODULE__{rescue_window: window}), do: window <= @reaction_ticks

  @doc "Whether callable debt is close to consuming the city's last affordable escape."
  @spec financing_warning?(t()) :: boolean()
  def financing_warning?(%__MODULE__{financing_locked: false}), do: false
  def financing_warning?(%__MODULE__{stalled: true}), do: false
  def financing_warning?(%__MODULE__{bankrupt: true}), do: false
  def financing_warning?(%__MODULE__{bond: %{defaulted: true}}), do: false
  def financing_warning?(%__MODULE__{financing_rescue_window: nil}), do: false

  def financing_warning?(%__MODULE__{financing_rescue_window: window}),
    do: window <= @reaction_ticks

  defp opening_planning?(%__MODULE__{bond: bond}),
    do: match?(%{legacy: false, started: false}, bond)

  defp calculate_avg_health([]), do: 0.0

  defp calculate_avg_health(nodes) do
    sum = Enum.reduce(nodes, 0.0, fn node, acc -> acc + node.health end)
    sum / length(nodes)
  end

  defp count_offline_nodes(nodes) do
    Enum.count(nodes, &(&1.status == :offline))
  end

  # `health > 0.0`, not a count and not a status. Residential is the only type that
  # consumes no labour, so it is the only source of labour supply; at exactly zero
  # health that supply is exactly 0.0 and every other type starves at the full decay
  # rate. A block at health 5 is `:offline` and still supplies 0.25 labour, so a
  # status-based reading would call a city doomed while it is still being staffed.
  defp housing_alive?(nodes) do
    Enum.any?(nodes, &(&1.type == :residential and &1.health > 0.0))
  end

  # Every type gets an entry, present or not, so the legend renders a stable set of
  # rows. Rated and actual are kept apart rather than reduced to one figure: capacity
  # scales with health and load does not, and that divergence is what makes a
  # collapse visible.
  defp build_by_type(
         nodes,
         health_labour_multiplier,
         crime_money_multiplier,
         inflation_multiplier
       ) do
    grouped = Enum.group_by(nodes, & &1.type)

    Map.new(Node.types(), fn type ->
      of_type = Map.get(grouped, type, [])

      {type,
       %{
         count: length(of_type),
         rated_capacity: scale(Node.capacity(type), length(of_type)),
         actual_capacity:
           sum_actual_capacity(
             type,
             of_type,
             health_labour_multiplier,
             crime_money_multiplier
           ),
         load: scale_load(Node.load(type), length(of_type), inflation_multiplier)
       }}
    end)
  end

  defp scale(table, count) do
    Map.new(table, fn {resource, amount} -> {resource, amount * count} end)
  end

  defp scale_load(table, count, inflation_multiplier) do
    scaled = scale(table, count)

    if Map.has_key?(scaled, :money),
      do: Map.update!(scaled, :money, &(&1 * inflation_multiplier)),
      else: scaled
  end

  # Keyed off the type's *base* capacity table rather than the nodes, so the keys are
  # the same whether or not any are placed.
  defp sum_actual_capacity(type, nodes, health_labour_multiplier, crime_money_multiplier) do
    type
    |> Node.capacity()
    |> Map.new(fn {resource, _base} ->
      total =
        Enum.reduce(nodes, 0.0, fn node, acc ->
          acc + Map.get(Node.effective_capacity(node), resource, 0.0)
        end)

      adjusted =
        cond do
          type == :residential and resource == :labour ->
            total * health_labour_multiplier

          type == :commercial and resource == :money ->
            total * crime_money_multiplier

          true ->
            total
        end

      {resource, adjusted}
    end)
  end
end
