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

  alias ArmchairMetropolist.Domain.Entities.CityMap
  alias ArmchairMetropolist.Domain.Entities.Node
  alias ArmchairMetropolist.Domain.Entities.SimulationMetrics
  alias ArmchairMetropolist.Domain.Services.SimulationCalculator, as: Calc
  alias ArmchairMetropolist.UseCases.ManageInfrastructure

  @resources [:power, :water, :waste, :traffic, :labour, :money]

  @doc "Every generated block, keyed by the marker name used in the markdown."
  @spec blocks() :: %{String.t() => String.t()}
  def blocks do
    %{
      "baseline" => baseline_block(),
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

  # The order that keeps every stage fully supplied, and it is not the order a player
  # reaches for. `commercial` is the only real earner and it goes **last**, because its
  # 22 power is exactly what would crowd the water plant's 25 out from under the free
  # baseline of 40: one house and one park draw 15, which leaves 25 and not a unit more.
  # That knife-edge is why the order is forced rather than chosen, and why the sequence
  # has to be walked with nothing earning.
  #
  # Written down rather than searched for. A search over orderings belongs in a scratch
  # script, not in a test-suite helper — but `opening_stages/0` measures the consequences
  # of this order, and `playing_guide_test.exs` fails if any stage stops being supplied,
  # so a balance patch cannot leave the sequence quietly wrong.
  @opening_order [
    :residential,
    :park,
    :water_plant,
    :power_plant,
    :residential,
    :park,
    :commercial
  ]

  # Money is deliberately not one of these. The sequence runs a money deficit through its
  # whole middle and leans on the treasury to cover it — that is the mechanic being
  # documented, not a fault. The five below have no such backstop: a shortfall in any of
  # them is decay on the very same tick.
  @physical [:power, :water, :waste, :traffic, :labour]

  # The detour a slower player takes: build the three-block earner first, bank the income,
  # then sell the shop to get back to stage 2 of the sequence above with money in hand.
  # Derived from `@opening_order` rather than written out, so the two cannot drift — the
  # earner really is the first two stages plus the commercial block.
  @earner_detour Enum.take(@opening_order, 2) ++ [:commercial]

  # Descending, so `Enum.find/3` returns the largest interval that survives.
  @gap_ladder [30, 25, 20, 16, 12, 10, 8, 6, 5, 4, 3, 2, 1]
  @slow_gaps [10, 20, 30, 60]
  @bank_ladder [300, 400, 500, 600, 800, 1000, 1200, 1600, 2000, 2400, 3000, 4000]

  # Long enough for a working sequence to climb back to 100 from the couple of points it
  # can lose, and far longer than a failing one needs to be unmistakably dead.
  @settle_ticks 200
  @recovered 99.9

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
      stats = @opening_order |> Enum.take(step) |> city_from() |> Calc.resource_stats()

      stage = %{
        step: step,
        type: type,
        cost: Node.construction_cost(type),
        spent: spent,
        tightest: tightest_physical(stats),
        money_flow: money_flow(stats)
      }

      {stage, spent}
    end)
    |> elem(0)
  end

  @doc """
  The solvency state at each stage of the documented opening, with the treasury the grant
  actually leaves at that point.

  Separate from `opening_stages/0` because it needs a *treasury*, and that function's cities
  are built by `city_from/1`, which deliberately starts broke to make its own decay window
  tight. Here the balance is the whole subject: the opening sequence is insolvent for five of
  its seven stages — money has no free baseline, and the shop that pays for the plants and
  parks goes up last — so a warning keyed off insolvency alone would fire right through the
  tutorial. What keeps it quiet is that the grant leaves a wide rescue window at every stage.
  """
  @spec opening_solvency() :: [
          %{step: pos_integer(), type: Node.node_type(), metrics: SimulationMetrics.t()}
        ]
  def opening_solvency do
    @opening_order
    |> Enum.with_index(1)
    |> Enum.map_reduce(0.0, fn {type, step}, spent ->
      spent = spent + Node.construction_cost(type)
      city = @opening_order |> Enum.take(step) |> city_from()
      metrics = Calc.metrics(%{city | money: CityMap.opening_grant() - spent})

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

  @doc """
  The largest gap between placements the sequence survives, straight from the grant.

  Measured through `ManageInfrastructure.place/4` rather than by putting nodes onto the
  map directly, because affordability is half of what is being asked: the treasury drains
  while the sequence is half-built, and a refused placement is exactly the failure this
  is looking for.
  """
  @spec opening_max_gap_ticks() :: non_neg_integer()
  def opening_max_gap_ticks do
    Enum.find(@gap_ladder, 0, fn gap ->
      # An explicit 40x30 and not `CityMap.new/0`. Every figure this module generates is
      # independent of grid size -- the simulation reads no coordinates -- and 40x30 is above
      # the growth cap, so capacity never binds and no measurement here can be perturbed by a
      # grid that grew mid-sequence. Migrating this to `new/0` would change what the guide
      # measures.
      CityMap.new(40, 30)
      |> run_sequence(@opening_order, gap)
      |> finished_healthy?()
    end)
  end

  @doc """
  How much a slower player must bank before selling the shop, per interval between clicks.

  The straight-through sequence has a deadline only because the grant is finite. Bank more
  first and the deadline goes away — this is the ladder of "more".
  """
  @spec slow_opening_rows() :: [%{gap_ticks: pos_integer(), bank: pos_integer()}]
  def slow_opening_rows do
    Enum.map(@slow_gaps, fn gap ->
      bank = Enum.find(@bank_ladder, &slow_route_survives?(&1, gap))

      unless bank do
        raise "slow_opening_rows: no bank up to #{List.last(@bank_ladder)} sustains " <>
                "#{gap} ticks between placements — the sell-the-shop route the guide " <>
                "recommends for slow play no longer works at that pace"
      end

      %{gap_ticks: gap, bank: bank}
    end)
  end

  @doc """
  What breaks when each type in turn is added to the three-block earner.

  The reason the opening above has to be a *sequence* rather than a next step: the
  cheapest earning city is a dead end for single additions, and this is the enumeration
  that says so. Every type overruns something, which is why the way forward is to take
  the whole run of seven at once.
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

  defp slow_route_survives?(bank, gap) do
    CityMap.new(40, 30)
    |> run_sequence(@earner_detour, 1)
    |> save_until(bank * 1.0)
    |> sell(:commercial)
    |> run_sequence(Enum.drop(@opening_order, 2), gap)
    |> finished_healthy?()
  end

  defp opening_block do
    rows =
      for stage <- opening_stages() do
        {resource, demanded, supplied, _satisfaction} = stage.tightest

        "| #{stage.step} | `#{stage.type}` | #{num(stage.cost)} | #{num(stage.spent)} " <>
          "| #{resource} #{num(demanded)}/#{num(supplied)} | #{signed(stage.money_flow)} |"
      end

    gap = opening_max_gap_ticks()

    Enum.join(
      [
        "| # | place | cost | spent so far | tightest resource | money |",
        "|---|---|---|---|---|---|"
      ] ++
        rows ++
        [
          "",
          "Total #{num(opening_cost())}, against an opening grant of " <>
            "#{num(CityMap.opening_grant())}. The finished city nets " <>
            "#{signed(opening_income())} per tick. Every stage is fully supplied on all " <>
            "five physical resources — the `tightest resource` column is demand against " <>
            "supply, so `40/40` is at capacity and not over it.",
          "",
          "Measured: starting cold from the grant, this holds at full health with up to " <>
            "**#{gap} ticks (#{num(gap * tick_ms() / 1000)} s) between placements**. " <>
            "Slower than that and the treasury empties mid-sequence."
        ],
      "\n"
    )
  end

  defp opening_pace_block do
    rows =
      for %{gap_ticks: gap, bank: bank} <- slow_opening_rows() do
        "| #{gap} ticks (#{num(gap * tick_ms() / 1000)} s) | #{bank} |"
      end

    Enum.join(
      ["| time between placements | bank this much first |", "|---|---|"] ++ rows,
      "\n"
    )
  end

  # --- sequence mechanics -------------------------------------------------

  defp run_sequence(city, types, gap) do
    Enum.reduce(types, city, fn type, city ->
      city |> place_or_skip(type) |> advance(gap)
    end)
  end

  # A refusal is left to show up as a missing block in `finished_healthy?/1` rather than
  # raised here: "the grant ran out at this pace" is a result, not an error.
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

  defp sell(city, type) do
    node = city |> CityMap.nodes() |> Enum.find(&(&1.type == type))
    {:ok, {city, _id}} = ManageInfrastructure.demolish(city, node.x, node.y)
    city
  end

  defp save_until(city, bank) do
    Enum.reduce_while(1..1000, city, fn _, city ->
      if city.money >= bank, do: {:halt, city}, else: {:cont, advance(city, 1)}
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

  # Ranked by demand as a fraction of supply, deliberately *not* by `satisfaction`.
  # Satisfaction is `min(1.0, supplied / demanded)`, so on a healthy city every resource
  # reads exactly 1.0 and the clamp throws away the margin — ranking by it made this
  # column say `power` at all seven stages, which is the first entry in `@physical` and
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

    {resource, stat.demanded, stat.supplied, tightness(stat)}
  end

  # Nothing in the documented sequence reaches here with no supply — every physical
  # resource but labour has the free baseline, and the sequence opens with the house that
  # supplies labour. The clause is here so a future stage that does cannot divide by zero
  # and silently rank itself last.
  # Guards rather than `%{demanded: 0.0}` patterns, matching `SimulationCalculator`'s own
  # `satisfaction/2`: a literal 0.0 pattern matches only +0.0 and warns about it.
  defp tightness(%{demanded: demanded}) when demanded == 0.0, do: 0.0
  defp tightness(%{supplied: supplied}) when supplied == 0.0, do: :infinity
  defp tightness(%{demanded: demanded, supplied: supplied}), do: demanded / supplied

  defp money_flow(stats) do
    money = Map.fetch!(stats, :money)
    money.supplied - money.demanded
  end

  defp city_from(types) do
    types |> Enum.frequencies() |> Enum.to_list() |> city_with()
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
            "A new city starts with #{num(CityMap.opening_grant())}."
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
  # These are solved, not guessed. {1,1,1,1,1} has NO viable residential count —
  # industrial and commercial demand 20 labour (r >= 5) while power caps r at 4 — so
  # the smallest set carries a second power plant.
  @support_sets [{2, 1, 1, 1, 1}, {2, 2, 1, 1, 1}, {3, 3, 2, 2, 2}]

  defp capacities_block do
    rows =
      for {pp, wp, ind, th, com} <- @support_sets do
        support = pp + wp + ind + th + com

        case residential_range(pp, wp, ind, th, com) do
          nil ->
            "| #{pp} power, #{wp} water, #{ind} industrial, #{th} transit, #{com} commercial " <>
              "| #{support} | none | none | none | none |"

          {min_r, max_r} ->
            total = support + max_r

            "| #{pp} power, #{wp} water, #{ind} industrial, #{th} transit, #{com} commercial " <>
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
  defp residential_range(pp, wp, ind, th, com) do
    sustainable =
      for r <- 1..40,
          city =
            city_with(
              power_plant: pp,
              water_plant: wp,
              industrial: ind,
              transit_hub: th,
              commercial: com,
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
    city = city_with(residential: 1) |> set_health(50.0)
    before = health_of(city)
    {advanced, _} = Calc.advance_tick(city)
    Float.round(health_of(advanced) - before, 4)
  end

  # Three residential blocks on the baseline alone are short of power, by a ratio the
  # calculator will report. Solve the decay rate out of the health it actually lost.
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

    # Not the 150.0 grant. Over the 120-tick window a city whose income falls one
    # short of its upkeep drains the grant at 1/tick and survives all 120 ticks —
    # so the guide would certify a city that goes bankrupt on tick 151. A smaller
    # grant makes this trap tighter rather than looser: even at 150 a 1/tick
    # shortfall still outlasts the window. Starting broke measures the
    # steady-state economy: income must cover upkeep every tick.
    %{city | money: 0.0}
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
end
