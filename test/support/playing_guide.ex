defmodule ArmchairMetropolist.PlayingGuide do
  @moduledoc """
  Renders the reference tables in `docs/PLAYING.md` from the domain itself.

  A strategy guide is worse than no guide once it disagrees with the simulation, and
  a table of numbers copied by hand into markdown is exactly the kind of thing that
  rots silently. So every number below is read out of `Node`'s tables or *measured by
  running* `SimulationCalculator`, and `playing_guide_test.exs` fails if the committed
  document no longer matches. Regenerate with:

      REGENERATE_PLAYING_GUIDE=1 mix test test/docs/playing_guide_test.exs

  The decay and regeneration rates are module attributes with no public accessor, so
  they are derived from observed behaviour rather than duplicated here: build a city
  with a known satisfaction, advance one tick, and solve for the rate. That way the
  guide tracks the rules even if the constants change.
  """

  use Boundary, top_level?: true, check: [in: false, out: false]

  alias ArmchairMetropolist.Domain.Entities.{CityMap, MunicipalBond, Node, SimulationMetrics}
  alias ArmchairMetropolist.Domain.Services.SimulationCalculator, as: Calc
  alias ArmchairMetropolist.UseCases.{BeginSimulation, IssueMunicipalBond, ManageInfrastructure}

  @resources Node.resources()

  @doc "Every generated block, keyed by the marker name used in the markdown."
  @spec blocks() :: %{String.t() => String.t()}
  def blocks do
    %{
      "baseline" => baseline_block(),
      "balanced_growth" => balanced_growth_block(),
      "bonds" => bonds_block(),
      "production" => production_block(),
      "consumption" => consumption_block(),
      "constants" => constants_block(),
      "capacities" => capacities_block(),
      "costs" => costs_block(),
      "opening" => opening_block(),
      "opening_pace" => opening_pace_block(),
      "opening_wall" => opening_wall_block()
    }
  end

  # --- the opening sequence -----------------------------------------------

  # One balanced plan, not a mandatory click order. Opening planning now freezes the clock
  # and refunds every undo, so the player can assemble these blocks in any order. The rows
  # still need a stable order so the guide can explain what each addition contributes.
  #
  # Written down rather than searched for. A search over orderings belongs in a scratch
  # script, not in a test-suite helper — but `opening_stages/0` measures the consequences
  # of this order, and `playing_guide_test.exs` fails if any stage stops being supplied,
  # so a balance patch cannot leave the sequence quietly wrong.
  @opening_order [
    :residential,
    :power_plant,
    :transit_hub,
    :commercial,
    :water_plant,
    :residential,
    :park,
    :park
  ]

  # Lean cannot afford the full eight-block plan before beginning. It assembles the same
  # four-block earning core during planning, begins the simulation, then saves for the
  # remaining support chain.
  @lean_order [
    :residential,
    :commercial,
    :power_plant,
    :transit_hub,
    :water_plant,
    :residential,
    :park,
    :park
  ]

  # The construction-only continuation for the recommended issue. It deliberately keeps
  # both opening parks: removing a beneficial amenity to survive the tutorial is legible as
  # a rescue tactic, not as the intended route. These five blocks turn the opening into a
  # hospital-protected city whose operating surplus can amortize the 400 issue.
  @balanced_no_demolition_expansion [
    :hospital,
    :commercial,
    :power_plant,
    :water_plant,
    :industrial
  ]
  @balanced_expansion_reserve 100.0

  # Money is deliberately not one of these. The sequence runs a money deficit through its
  # whole middle and leans on the treasury to cover it — that is the mechanic being
  # documented, not a fault. The five below have no such backstop: a shortfall in any of
  # them is decay on the very same tick.
  @physical [:power, :water, :waste, :traffic, :injuries, :disease, :labour]

  # The first four blocks form the earner. Derived from `@opening_order` so the expansion
  # wall and the documented route cannot drift apart.
  @earner_detour Enum.take(@opening_order, 4)

  # Long enough for a working sequence to climb back to 100 from the couple of points it
  # can lose, and far longer than a failing one needs to be unmistakably dead.
  @settle_ticks 200
  @recovered 99.9
  @recommended_issue MunicipalBond.recommended_issue()

  @doc """
  Each stage of the documented opening, with what it costs and what it leaves tightest.

  Measured against the city as it stands *after* that stage, every node at full health —
  which is the situation the guide describes: a player who keeps up never sees decay, so
  the question at each stage is whether the blocks placed so far cover each other.
  """
  @spec opening_stages() :: [map()]
  def opening_stages do
    @opening_order
    |> Enum.with_index(1)
    |> Enum.map_reduce(0.0, fn {type, step}, spent ->
      spent = spent + Node.construction_cost(type)

      city =
        @opening_order
        |> Enum.take(step)
        |> financed_city_from(@recommended_issue, spent)

      metrics = Calc.metrics(city)
      stats = metrics.resources

      stage = %{
        step: step,
        type: type,
        cost: Node.construction_cost(type),
        spent: spent,
        tightest: tightest_physical(stats),
        money_flow: money_flow(stats) - metrics.market_spend
      }

      {stage, spent}
    end)
    |> elem(0)
  end

  @doc """
  The solvency state at each stage of the documented opening, with the treasury the
  recommended bond issue actually leaves at that point.

  Separate from `opening_stages/0` because it needs a *treasury*, and that function's cities
  are built by `city_from/1`, which deliberately starts broke to make its own decay window
  tight. Here the balance is the whole subject: the opening sequence is briefly insolvent
  before commerce arrives at step 4, so a warning keyed off insolvency alone can still fire
  through the tutorial. What keeps it quiet is that the issue leaves a wide rescue window.
  """
  @spec opening_solvency() :: [
          %{step: pos_integer(), type: Node.node_type(), metrics: SimulationMetrics.t()}
        ]
  def opening_solvency do
    @opening_order
    |> Enum.with_index(1)
    |> Enum.map_reduce(0.0, fn {type, step}, spent ->
      spent = spent + Node.construction_cost(type)
      city = @opening_order |> Enum.take(step) |> financed_city_from(@recommended_issue, spent)
      metrics = Calc.metrics(city)

      {%{step: step, type: type, metrics: metrics}, spent}
    end)
    |> elem(0)
  end

  @doc "What the whole documented opening costs to build."
  @spec opening_cost() :: float()
  def opening_cost do
    @opening_order |> Enum.map(&Node.construction_cost/1) |> Enum.sum()
  end

  @doc "What the finished city nets per tick."
  @spec opening_income() :: float()
  def opening_income do
    @opening_order |> city_from() |> Calc.resource_stats() |> money_flow()
  end

  @doc "Whether an issue can plan the complete opening before starting and remain healthy."
  @spec direct_planning_healthy?(float()) :: boolean()
  def direct_planning_healthy?(principal) when principal in [400.0, 550.0] do
    principal
    |> financed_city()
    |> place_all(@opening_order)
    |> begin_or_keep()
    |> finished_healthy?()
  end

  @doc "Whether Lean can complete the opening by reaching commerce quickly, then saving."
  @spec lean_save_and_grow_healthy?() :: boolean()
  def lean_save_and_grow_healthy? do
    financed_city(250.0)
    |> run_save_and_grow_sequence(@lean_order)
    |> finished_healthy?()
  end

  @doc "Whether an issue's documented route avoids warning and default at every step."
  @spec documented_route_safe?(float()) :: boolean()
  def documented_route_safe?(250.0) do
    {_city, safe?} = run_save_and_grow_checked(financed_city(250.0), @lean_order)
    safe?
  end

  def documented_route_safe?(principal) when principal in [400.0, 550.0] do
    {_city, safe?} = run_direct_planning_checked(financed_city(principal), @opening_order)
    safe?
  end

  @doc "Measured construction-only continuation for the recommended issue."
  @spec balanced_no_demolition_route() :: map()
  def balanced_no_demolition_route do
    expansion_cost = construction_cost(@balanced_no_demolition_expansion)
    construction_budget = expansion_cost + @balanced_expansion_reserve

    opening =
      financed_city(@recommended_issue)
      |> place_all(@opening_order)
      |> begin_or_keep()

    {funded, wait_safe?} = advance_until_funded_checked(opening, construction_budget, 60)
    expanded = place_all(funded, @balanced_no_demolition_expansion)
    expanded_metrics = Calc.metrics(expanded)
    operating_flow = money_flow(expanded_metrics.resources) - expanded_metrics.market_spend
    {settled, settle_safe?} = advance_checked(expanded, 160)
    nodes = CityMap.nodes(settled)

    %{
      expansion: @balanced_no_demolition_expansion,
      expansion_cost: expansion_cost,
      reserve_after_expansion: funded.money - expansion_cost,
      funded_tick: funded.tick,
      funded_treasury: funded.money,
      operating_flow: operating_flow,
      traffic_demand: expanded_metrics.resources.traffic.demanded,
      traffic_supply: expanded_metrics.resources.traffic.supplied,
      stable?:
        wait_safe? and settle_safe? and
          length(nodes) == length(@opening_order) + length(@balanced_no_demolition_expansion) and
          Enum.all?(nodes, &(&1.health >= @recovered)) and
          MunicipalBond.debt_free?(settled.municipal_bond) and
          not MunicipalBond.defaulted?(settled.municipal_bond)
    }
  end

  @doc "Whether the finished documented city retires an issue on schedule from zero cash."
  @spec opening_retires_issue?(float()) :: boolean()
  def opening_retires_issue?(principal) do
    {:ok, bond} = MunicipalBond.new(principal)

    city =
      @opening_order
      |> city_from()
      |> Map.merge(%{tick: 20, money: 0.0, municipal_bond: MunicipalBond.start(bond, 0)})
      |> advance(MunicipalBond.term_ticks())

    MunicipalBond.debt_free?(city.municipal_bond) and
      not MunicipalBond.defaulted?(city.municipal_bond)
  end

  @doc "The next-tick cash-flow gain from removing debt, beside the quoted payment."
  @spec redemption_cash_flow_gain(float()) :: {float(), float()}
  def redemption_cash_flow_gain(principal) do
    {:ok, bond} = MunicipalBond.new(principal)
    bond = MunicipalBond.start(bond, 0)

    bond =
      Enum.reduce(20..39, bond, fn tick, current ->
        MunicipalBond.service(current, tick, 10_000.0).bond
      end)

    active =
      @opening_order
      |> city_from()
      |> Map.merge(%{tick: 40, money: 100.0, municipal_bond: bond})

    quote = MunicipalBond.quote(bond, active.tick)
    {:ok, redeemed_bond} = MunicipalBond.redeem(bond, active.tick, quote.redemption_amount)
    redeemed = %{active | municipal_bond: redeemed_bond}

    active_next = active |> Calc.advance_tick() |> elem(0)
    redeemed_next = redeemed |> Calc.advance_tick() |> elem(0)

    {redeemed_next.money - active_next.money, quote.next_payment}
  end

  @doc """
  Which local resource runs short when each type is added to the four-block earner.

  Market purchases can sustain several of these expansions. This enumeration instead
  shows why no fourth block remains import-free and what recurring bill it introduces.
  """
  @spec opening_wall_rows() :: [%{type: atom(), tightest: tuple()}]
  def opening_wall_rows do
    for type <- sorted_types() do
      stats = (@earner_detour ++ [type]) |> city_from() |> Calc.resource_stats()
      %{type: type, tightest: tightest_physical(stats)}
    end
  end

  defp opening_wall_block do
    rows =
      for %{type: type, tightest: {resource, demanded, supplied, _}} <- opening_wall_rows() do
        "| `#{type}` | #{resource} #{num(demanded)}/#{num(supplied)} |"
      end

    Enum.join(
      ["| add this to the earner | what overruns |", "|---|---|"] ++ rows,
      "\n"
    )
  end

  defp opening_block do
    lean_terms = bond_terms(250.0)
    balanced_terms = bond_terms(400.0)
    generous_terms = bond_terms(550.0)

    rows =
      for stage <- opening_stages() do
        {resource, demanded, supplied, _satisfaction} = stage.tightest

        "| #{stage.step} | `#{stage.type}` | #{num(stage.cost)} | #{num(stage.spent)} " <>
          "| #{resource} #{num(demanded)}/#{num(supplied)} | #{signed(stage.money_flow)} |"
      end

    lean_core_cost =
      @lean_order |> Enum.take(4) |> Enum.map(&Node.construction_cost/1) |> Enum.sum()

    Enum.join(
      [
        "| # | place | cost | spent so far | tightest resource | projected money/tick |",
        "|---|---|---|---|---|---|"
      ] ++
        rows ++
        [
          "",
          "Total #{num(opening_cost())}, against the recommended #{num(@recommended_issue)} " <>
            "bond issue. The finished city nets " <>
            "#{signed(opening_income())} per tick. Every stage is fully supplied on all " <>
            "seven physical resources — the `tightest resource` column is demand against " <>
            "available supply, including purchases, so step 1's `15/15` is imported power.",
          "",
          "| issue | principal | opening plan | reserve when sim begins | first payment | total interest |",
          "|---|---:|---|---|---:|---:|",
          "| Lean | 250 | plan the four-block earning core, begin, then save and grow | " <>
            "#{num(250.0 - lean_core_cost)} | #{money2(lean_terms.first_payment)} | " <>
            "#{money2(lean_terms.total_interest)} |",
          "| **Balanced · recommended** | **400** | plan all eight blocks, then begin | " <>
            "**#{num(400.0 - opening_cost())}** | " <>
            "**#{money2(balanced_terms.first_payment)}** | " <>
            "**#{money2(balanced_terms.total_interest)}** |",
          "| Generous | 550 | plan all eight blocks, then begin | " <>
            "#{num(550.0 - opening_cost())} | " <>
            "#{money2(generous_terms.first_payment)} | " <>
            "#{money2(generous_terms.total_interest)} |",
          "",
          "All three issues include an untimed opening-planning phase with full-refund undo. " <>
            "Begin sim starts both the city clock and a 20-tick debt-service grace period; " <>
            "the bond then has 100 servicing ticks, level principal, and 0.5% interest per tick."
        ],
      "\n"
    )
  end

  defp opening_pace_block do
    "The four-block commercial core has +6 of operating cash flow per tick. " <>
      "Debt service is separate: Lean can begin at the core, save through its 20-tick grace " <>
      "period, and then cover a first payment of 3.75. Balanced and Generous can plan all eight " <>
      "blocks before beginning; the finished opening's +12 flow covers their first payments of " <>
      "6.00 and 8.25."
  end

  defp balanced_growth_block do
    route = balanced_no_demolition_route()
    additions = Enum.map_join(route.expansion, ", ", &"`#{&1}`")

    "Keep every opening block. Let the finished Balanced opening save until tick " <>
      "#{route.funded_tick}, when its treasury reaches #{num(route.funded_treasury)}, then add " <>
      "#{additions} for #{num(route.expansion_cost)} total. No demolition is required. " <>
      "That leaves a #{num(route.reserve_after_expansion)} operating reserve. " <>
      "The expanded city has #{signed(route.operating_flow)} of operating cash flow before " <>
      "debt service and traffic #{num(route.traffic_demand)}/#{num(route.traffic_supply)}; its " <>
      "hospital clears the periodic health burden while that surplus retires the bond."
  end

  defp bonds_block do
    rows =
      for principal <- MunicipalBond.issues() do
        terms = bond_terms(principal)

        label =
          if principal == MunicipalBond.recommended_issue(),
            do: "**Balanced · recommended**",
            else: issue_name(principal)

        "| #{label} | #{num(principal)} | #{money2(terms.principal_payment)} | " <>
          "#{money2(terms.first_interest)} | #{money2(terms.first_payment)} | " <>
          "#{money2(terms.total_interest)} | #{money2(terms.final_payment)} |"
      end

    Enum.join(
      [
        "| issue | proceeds | principal/tick | first interest | first payment | total interest | final payment |",
        "|---|---:|---:|---:|---:|---:|---:|"
      ] ++ rows,
      "\n"
    )
  end

  defp bond_terms(principal) do
    MunicipalBond.issue_terms(principal)
  end

  defp issue_name(250.0), do: "Lean"
  defp issue_name(400.0), do: "Balanced"
  defp issue_name(550.0), do: "Generous"

  defp construction_cost(types), do: types |> Enum.map(&Node.construction_cost/1) |> Enum.sum()

  # --- sequence mechanics -------------------------------------------------

  defp run_save_and_grow_sequence(city, types) do
    remaining_cost = types |> Enum.drop(4) |> Enum.map(&Node.construction_cost/1) |> Enum.sum()

    types
    |> Enum.with_index(1)
    |> Enum.reduce(city, fn {type, step}, city ->
      city = if step == 5, do: advance_until_funded(city, remaining_cost, 200), else: city
      city = place_or_skip(city, type)
      city = if step == 4, do: begin_or_keep(city), else: city
      if step < 4, do: city, else: advance(city, 1)
    end)
  end

  defp run_direct_planning_checked(city, types) do
    {city, safe?} =
      Enum.reduce(types, {city, true}, fn type, {city, safe?} ->
        city = place_or_skip(city, type)
        {city, safe? and route_state_safe?(city)}
      end)

    city = begin_or_keep(city)
    {city, safe? and route_state_safe?(city)}
  end

  defp place_all(city, types) do
    Enum.reduce(types, city, fn type, city ->
      city = place_or_skip(city, type)
      city
    end)
  end

  defp run_save_and_grow_checked(city, types) do
    remaining_cost = types |> Enum.drop(4) |> Enum.map(&Node.construction_cost/1) |> Enum.sum()

    types
    |> Enum.with_index(1)
    |> Enum.reduce({city, true}, fn {type, step}, {city, safe?} ->
      {city, waiting_safe?} =
        if step == 5,
          do: advance_until_funded_checked(city, remaining_cost, 200),
          else: {city, true}

      city = place_or_skip(city, type)
      city = if step == 4, do: begin_or_keep(city), else: city
      {city, tick_safe?} = if step < 4, do: {city, true}, else: advance_checked(city, 1)
      {city, safe? and waiting_safe? and route_state_safe?(city) and tick_safe?}
    end)
  end

  defp begin_or_keep(city) do
    case BeginSimulation.execute(city) do
      {:ok, started} -> started
      {:error, _reason} -> city
    end
  end

  defp advance_until_funded_checked(city, amount, ticks_left) do
    cond do
      city.money >= amount ->
        {city, true}

      ticks_left == 0 ->
        {city, false}

      true ->
        {next, safe?} = advance_checked(city, 1)
        {final, rest_safe?} = advance_until_funded_checked(next, amount, ticks_left - 1)
        {final, safe? and rest_safe?}
    end
  end

  defp advance_checked(city, ticks) do
    Enum.reduce(1..ticks//1, {city, true}, fn _, {city, safe?} ->
      next = city |> Calc.advance_tick() |> elem(0)
      {next, safe? and route_state_safe?(next)}
    end)
  end

  defp route_state_safe?(city) do
    metrics = Calc.metrics(city)

    not (metrics.bond && metrics.bond.defaulted) and
      not SimulationMetrics.warning?(metrics) and
      not SimulationMetrics.financing_warning?(metrics)
  end

  defp advance_until_funded(city, amount, ticks_left) do
    cond do
      city.money >= amount -> city
      ticks_left == 0 -> city
      true -> city |> advance(1) |> advance_until_funded(amount, ticks_left - 1)
    end
  end

  # A refusal is left to show up as a missing block in `finished_healthy?/1` rather than
  # raised here: "the issue proceeds ran out at this pace" is a result, not an error.
  #
  # The cell is searched for rather than derived from a loop index. Position has no effect
  # on the simulation (see "Position does not matter"), so any free cell is as good as any
  # other — but the slow route runs two sequences over one city and frees a cell in
  # between, and an index restarting at zero collided with the blocks already standing.
  # Every placement was then refused as `:occupied`, which reads exactly like "the pace
  # was too slow".
  defp place_or_skip(city, type) do
    {x, y} = first_free_cell(city)

    case ManageInfrastructure.place(city, x, y, type) do
      {:ok, {city, _node}} -> city
      {:error, _reason} -> city
    end
  end

  defp first_free_cell(city) do
    Enum.find_value(0..(city.height - 1), fn y ->
      Enum.find_value(0..(city.width - 1), fn x ->
        unless CityMap.occupied?(city, x, y), do: {x, y}
      end)
    end)
  end

  # Both halves matter. A sequence that lost a block to a refusal is a failure even if
  # what remains is healthy, and a full set of blocks sitting at 40 health is a failure
  # too. Checked per node rather than against `avg_health`, so one dead block cannot hide
  # inside six live ones.
  defp finished_healthy?(city) do
    nodes = city |> advance(@settle_ticks) |> CityMap.nodes()

    length(nodes) == length(@opening_order) and
      Enum.all?(nodes, &(&1.health >= @recovered))
  end

  defp advance(city, ticks) do
    Enum.reduce(1..ticks//1, city, fn _, city -> elem(Calc.advance_tick(city), 0) end)
  end

  # Ranked by demand as a fraction of available supply, deliberately *not* by
  # `satisfaction`. Available supply includes automatic market purchases: the first
  # house is fully served even though all 15 power comes from the market.
  # Satisfaction is `min(1.0, supplied / demanded)`, so on a healthy city every resource
  # reads exactly 1.0 and the clamp throws away the margin — ranking by it made this
  # column say `power` at all eight stages, which is the first entry in `@physical` and
  # nothing more. The unclamped ratio is what moves, and what it shows is the binding
  # constraint walking from power to water to waste as the sequence goes up.
  #
  # A ratio at or below 1.0 says the same thing as satisfaction 1.0, and carries how much
  # room is left as well, which is why `playing_guide_test.exs` asserts on it.
  defp tightest_physical(stats) do
    {resource, stat} =
      @physical
      |> Enum.map(&{&1, Map.fetch!(stats, &1)})
      |> Enum.max_by(fn {_resource, stat} -> tightness(stat) end)

    {resource, stat.demanded, available_supply(stat), tightness(stat)}
  end

  # The clause is here so a future unfunded stage with no local or purchased supply cannot
  # divide by zero and silently rank itself last.
  # Guards rather than `%{demanded: 0.0}` patterns, matching `SimulationCalculator`'s own
  # `satisfaction/2`: a literal 0.0 pattern matches only +0.0 and warns about it.
  defp tightness(%{demanded: demanded}) when demanded == 0.0, do: 0.0

  defp tightness(stat) do
    case available_supply(stat) do
      supplied when supplied == 0.0 -> :infinity
      supplied -> stat.demanded / supplied
    end
  end

  defp available_supply(stat), do: stat.supplied + stat.purchased

  defp money_flow(stats) do
    money = Map.fetch!(stats, :money)
    money.supplied - money.demanded
  end

  defp city_from(types) do
    types |> Enum.frequencies() |> Enum.to_list() |> city_with()
  end

  defp financed_city_from(types, principal, spent) do
    {:ok, bond} = MunicipalBond.new(principal)

    types
    |> city_from()
    |> Map.put(:money, principal - spent)
    |> Map.put(:municipal_bond, MunicipalBond.start(bond, 0))
  end

  defp financed_city(principal) do
    {:ok, city} = IssueMunicipalBond.execute(CityMap.new(40, 30), principal)
    city
  end

  # Typographic minus (U+2212), because this is prose (money flow, opening income) rather
  # than a table cell mirroring the screen — contrast `signed_num/2` below, which renders
  # ASCII `-` specifically to match `SimulatorLive`'s own cells.
  defp signed(value) when value < 0, do: "−#{num(abs(value))}"
  defp signed(value), do: "+#{num(value)}"

  defp costs_block do
    rows = for type <- sorted_types(), do: "| `#{type}` | #{num(Node.construction_cost(type))} |"

    Enum.join(
      ["| type | cost to build |", "|---|---|"] ++
        rows ++
        [
          "",
          "Demolishing anything costs #{num(Node.demolition_cost())}, whatever it was. " <>
            "A new city starts with no cash; authorize a 250, 400 or 550 opening municipal " <>
            "bond issue before construction. Those proceeds are debt, not a grant. " <>
            "A qualifying healthy city may later receive one dynamically quoted commercial " <>
            "bridge covering the gap to 40 plus six projected ticks of expenses."
        ],
      "\n"
    )
  end

  # The numbers a player actually acts on, so they are worth generating rather than
  # asserting in prose. Each is found by simulation: add residential until the city
  # stops holding at full health.
  #
  # Commercial is part of a viable support set now, not an optional extra: without it
  # a city's only income is 1 per residential, which cannot cover the water plants and
  # transit hubs that residential itself requires.
  #
  # Hospitals are part of every durable support set: without treatment the periodic
  # outbreaks accumulate until labour collapses, however generous the utility margins.
  @support_sets [{2, 2, 1, 1, 1, 1}, {3, 3, 2, 2, 2, 1}, {7, 6, 4, 4, 3, 2}]

  defp capacities_block do
    rows =
      for {pp, wp, ind, th, com, hosp} <- @support_sets do
        support = pp + wp + ind + th + com + hosp

        case residential_range(pp, wp, ind, th, com, hosp) do
          nil ->
            "| #{pp} power, #{wp} water, #{ind} industrial, #{th} transit, #{com} commercial, #{hosp} hospital " <>
              "| #{support} | none | none | none | none |"

          {min_r, max_r} ->
            total = support + max_r

            "| #{pp} power, #{wp} water, #{ind} industrial, #{th} transit, #{com} commercial, #{hosp} hospital " <>
              "| #{support} | #{min_r} | **#{max_r}** | #{total} | #{Float.round(max_r / total, 2)} |"
        end
      end

    Enum.join(
      [
        "| support set | support tiles | min residential | max residential | total tiles | residential per tile |",
        "|---|---|---|---|---|---|"
      ] ++ rows,
      "\n"
    )
  end

  # Labour makes the low end fail too — too few residents cannot staff the
  # industry — so the sustainable set is a band, not a prefix, and the old
  # `reduce_while` that halted on the first failure returned 0. Scan the whole
  # range and report both ends.
  #
  # Returns {min, max}, or nil when no residential count is sustainable.
  #
  # 120 ticks is ample: a shortfall of even 2% costs ~0.12 health per tick, so
  # anything unsustainable is visibly below 100 long before then.
  #
  # Scan the full range; do not bisect. A two-sided binary search would find
  # the same band in a fraction of the simulations, and it would be wrong the
  # first time the band is not contiguous -- a failure that shows up as a
  # plausible wrong number in a published document, not as a test failure.
  defp residential_range(pp, wp, ind, th, com, hosp) do
    sustainable =
      for r <- 1..40,
          city =
            city_with(
              power_plant: pp,
              water_plant: wp,
              industrial: ind,
              transit_hub: th,
              commercial: com,
              hospital: hosp,
              residential: r
            ),
          final = Enum.reduce(1..120, city, fn _, c -> elem(Calc.advance_tick(c), 0) end),
          Calc.metrics(final).avg_health >= 99.9,
          do: r

    case sustainable do
      [] ->
        nil

      rs ->
        min_r = Enum.min(rs)
        max_r = Enum.max(rs)

        # The guard the comment above argues for but the old code never installed:
        # a non-contiguous band (e.g. {5, 7} sustainable via 5 and 7 but not 6) would
        # otherwise publish "5 to 7" and silently certify the gap. Recompute the count
        # a contiguous band would have and compare it to the one actually found.
        unless max_r - min_r + 1 == length(rs) do
          raise "residential_range: sustainable set #{inspect(rs)} is not contiguous — " <>
                  "publishing {#{min_r}, #{max_r}} would certify unsustainable counts in between"
        end

        {min_r, max_r}
    end
  end

  defp baseline_block do
    caps = Calc.baseline_capacity()
    header = "| " <> Enum.map_join(@resources, " | ", &"#{&1}") <> " |"
    rule = "|" <> String.duplicate("---|", length(@resources))
    row = "| " <> Enum.map_join(@resources, " | ", &num(Map.fetch!(caps, &1))) <> " |"

    Enum.join([header, rule, row], "\n")
  end

  defp production_block do
    rows =
      for type <- sorted_types(), not Enum.empty?(capacity_of(type)) do
        produced = capacity_of(type)

        # Iterated in the display-order @resources list rather than the raw map's
        # key order: a map's key order is a hash-seed artifact, not a decision
        # anyone made, and residential (labour + money, as of this task) is the
        # first capacity entry with two keys to expose that non-determinism.
        outputs =
          @resources
          |> Enum.filter(&Map.has_key?(produced, &1))
          |> Enum.map_join(", ", fn r -> "#{r} #{signed_num(r, Map.fetch!(produced, r))}" end)

        "| `#{type}` | #{outputs} |"
      end

    non_producers =
      sorted_types()
      |> Enum.filter(&Enum.empty?(capacity_of(&1)))
      |> Enum.map_join(", ", &"`#{&1}`")

    # Commercial's money capacity means every type produces something now, so
    # there is no non-producer list to print — `Enum.empty?` sidesteps the dead
    # comparison `== %{}` would be (every capacity map is non-empty at the
    # type level too, which is what made that comparison a compiler warning).
    footer =
      if non_producers == "" do
        "Every type has a health-scaled effect."
      else
        "No health-scaled effect: #{non_producers}."
      end

    Enum.join(
      ["| type | effect |", "|---|---|"] ++ rows ++ ["", footer],
      "\n"
    )
  end

  defp consumption_block do
    header = "| type | " <> Enum.map_join(@resources, " | ", &"#{&1}") <> " |"
    rule = "|---|" <> String.duplicate("---|", length(@resources))

    rows =
      for type <- sorted_types() do
        consumed = Node.load(type)

        cells =
          Enum.map_join(@resources, " | ", fn r ->
            case Map.get(consumed, r) do
              nil -> "—"
              amount -> signed_num(r, -amount)
            end
          end)

        "| `#{type}` | #{cells} |"
      end

    Enum.join([header, rule] ++ rows, "\n")
  end

  defp constants_block do
    {online, degraded} = status_thresholds()

    Enum.join(
      [
        "| rule | value |",
        "|---|---|",
        "| health regained per tick when every consumed resource is fully supplied | **+#{num(regen_rate())}** |",
        "| health lost per tick, per unit of shortfall | **−#{num(decay_rate())} × (1 − satisfaction)** |",
        "| labour supply, multiplied per park per housing block | **+#{num(amenity_coefficient())} × (parks ÷ housing)** |",
        "| that multiplier's ceiling, at #{num(amenity_cap_ratio())} park per housing block | **×#{num(amenity_ceiling())}** |",
        "| healthy traffic ceiling | **#{num(Calc.initial_healthy_traffic_ratio() * 100)}% at no utilization, falling linearly to #{num(Calc.minimum_healthy_traffic_ratio() * 100)}% at full utilization** |",
        "| injuries above that ceiling | **+1 per #{num(1.0 / Calc.injuries_per_excess_traffic())} excess traffic** |",
        "| disease outbreak | **+#{num(Calc.disease_per_residential())} per residential; every #{Calc.disease_outbreak_interval(1)} ticks with one home, #{Calc.disease_outbreak_interval(1) - Calc.disease_outbreak_interval(2)} ticks sooner per additional home (minimum #{Calc.disease_outbreak_interval(20)})** |",
        "| untreated cases that suppress one residential block's labour | **#{num(Calc.health_burden_tolerance_per_housing())}** |",
        "| `:online` at | health ≥ #{num(online)} |",
        "| `:degraded` at | health ≥ #{num(degraded)} |",
        "| `:offline` below | health #{num(degraded)} |",
        "| tick length | #{tick_ms()} ms |"
      ],
      "\n"
    )
  end

  # --- measured, not copied ------------------------------------------------

  # A city that is comfortably supplied: its residential block regenerates, and the
  # health it gains in one tick *is* the regeneration rate.
  #
  # The block must be damaged first. Health is clamped to 100, so measuring a node that
  # starts at full health reports a gain of zero — which is what the first version of
  # this did, putting "+0" in the published guide.
  defp regen_rate do
    city = city_with(residential: 1) |> Map.put(:money, 100.0) |> set_health(50.0)
    before = health_of(city)
    {advanced, _} = Calc.advance_tick(city)
    Float.round(health_of(advanced) - before, 4)
  end

  # Three unfunded residential blocks have no power. Solve the decay rate out of the
  # health they actually lose.
  defp decay_rate do
    city = city_with(residential: 3)
    satisfaction = city |> Calc.metrics() |> worst_satisfaction()
    before = health_of(city)
    {advanced, _} = Calc.advance_tick(city)
    lost = before - health_of(advanced)

    Float.round(lost / (1.0 - satisfaction), 4)
  end

  # Two housing and one park is ratio 0.5 — below the cap — so the fractional gain in
  # labour supply over the same city with no park is `k * 0.5`. Solve for k. (Two housing
  # supply 10.0 unparked and 15.0 with the park, so this reads (1.5 - 1) / 0.5 = 1.0.)
  defp amenity_coefficient do
    base = labour_supplied(city_with(residential: 2))
    parked = labour_supplied(city_with(residential: 2, park: 1))

    Float.round((parked / base - 1.0) / 0.5, 4)
  end

  # The ratio at which more parks stop adding labour. Scanned rather than restated, so
  # a change to the cap moves the guide.
  defp amenity_cap_ratio do
    housing = 4

    Enum.find_value(1..40, fn parks ->
      here = labour_supplied(city_with(residential: housing, park: parks))
      next = labour_supplied(city_with(residential: housing, park: parks + 1))

      if here == next, do: Float.round(parks / housing, 4)
    end)
  end

  # Far past the cap, so this is the ceiling itself rather than a point on the way up.
  defp amenity_ceiling do
    base = labour_supplied(city_with(residential: 2))

    Float.round(labour_supplied(city_with(residential: 2, park: 20)) / base, 4)
  end

  defp labour_supplied(city) do
    city |> Calc.resource_stats() |> Map.fetch!(:labour) |> Map.fetch!(:supplied)
  end

  # Scanned rather than restated, so a change to `status_for/1` moves the guide.
  defp status_thresholds do
    healths = Enum.map(0..1000, &(&1 / 10))

    {Enum.find(healths, &(Node.status_for(&1) == :online)),
     Enum.find(healths, &(Node.status_for(&1) == :degraded))}
  end

  defp tick_ms, do: Application.get_env(:armchair_metropolist, :tick_interval_ms, 1000)

  # --- helpers ------------------------------------------------------------

  defp sorted_types, do: Enum.sort(Node.types())

  # Not to be confused with `capacities_block/0` above: that renders the generated
  # residential-support table (how many housing tiles a support set sustains, computed
  # by simulation); this reads a single type's row straight out of `Node`'s capacity table.
  defp capacity_of(type), do: Node.capacity(type)

  defp city_with(counts) do
    {city, _} =
      Enum.reduce(counts, {CityMap.new(40, 30), 0}, fn {type, n}, acc ->
        Enum.reduce(1..n//1, acc, fn _, {map, i} ->
          {CityMap.put_node(map, Node.new(rem(i, 40), div(i, 40), type)), i + 1}
        end)
      end)

    # Not bond proceeds. Over the 120-tick window a city whose income falls one
    # short of its upkeep drains a treasury at 1/tick and survives all 120 ticks —
    # so the guide would certify a city that goes bankrupt on tick 151. A smaller
    # treasury makes this trap tighter rather than looser: even at 150 a 1/tick
    # shortfall still outlasts the window. Starting broke measures the
    # steady-state economy: income must cover upkeep every tick.
    %{city | money: 0.0, municipal_bond: MunicipalBond.legacy()}
  end

  defp health_of(city) do
    city |> CityMap.nodes() |> List.first() |> Map.fetch!(:health)
  end

  defp set_health(city, health) do
    nodes =
      Map.new(city.nodes, fn {key, node} ->
        {key, %{node | health: health, status: Node.status_for(health)}}
      end)

    %{city | nodes: nodes}
  end

  defp worst_satisfaction(metrics) do
    metrics.resources |> Map.values() |> Enum.map(& &1.satisfaction) |> Enum.min()
  end

  # A table cell's *displayed* effect on a resource, sign included, matching the legend's
  # `net/3`. For a negative resource a positive figure means the block adds to the problem:
  # `industrial` removes 90 waste and renders `-90`, a house emits 10 and renders `+10`.
  #
  # ASCII `-`, not U+2212, because that is what `SimulatorLive.signed/1` emits and the guide
  # must not disagree with the screen it describes. Contrast this module's own `signed/1`
  # above, which uses the typographic minus for prose that never sits beside a screen cell.
  defp signed_num(resource, amount) do
    amount = if Node.negative_resource?(resource), do: -amount, else: amount

    if amount > 0, do: "+#{num(amount)}", else: num(amount)
  end

  # 120.0 reads as noise in a table; 120 does not. Keeps one decimal when it matters.
  defp num(value) when is_float(value) do
    if value == Float.round(value),
      do: value |> trunc() |> Integer.to_string(),
      else: to_string(value)
  end

  defp num(value), do: to_string(value)

  defp money2(value), do: :erlang.float_to_binary(value * 1.0, decimals: 2)
end
