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
  alias ArmchairMetropolist.Domain.Services.SimulationCalculator, as: Calc

  @resources [:power, :water, :waste, :traffic, :labour, :money]

  @doc "Every generated block, keyed by the marker name used in the markdown."
  @spec blocks() :: %{String.t() => String.t()}
  def blocks do
    %{
      "baseline" => baseline_block(),
      "production" => production_block(),
      "consumption" => consumption_block(),
      "constants" => constants_block(),
      "capacities" => capacities_block()
    }
  end

  # The numbers a player actually acts on, so they are worth generating rather than
  # asserting in prose. Each is found by simulation: add residential until the city
  # stops holding at full health.
  #
  # Commercial is part of a viable support set now, not an optional extra: without it
  # a city's only income is 1 per residential, which cannot cover the water plants and
  # road hubs that residential itself requires.
  #
  # These are solved, not guessed. {1,1,1,1,1} has NO viable residential count —
  # industrial and commercial demand 20 labour (r >= 5) while power caps r at 4 — so
  # the smallest set carries a second power plant.
  @support_sets [{2, 1, 1, 1, 1}, {2, 2, 1, 1, 1}, {3, 3, 2, 2, 2}]

  defp capacities_block do
    rows =
      for {pp, wp, ind, rh, com} <- @support_sets do
        support = pp + wp + ind + rh + com

        case residential_range(pp, wp, ind, rh, com) do
          nil ->
            "| #{pp} power, #{wp} water, #{ind} industrial, #{rh} road, #{com} commercial " <>
              "| #{support} | none | none | none | none |"

          {min_r, max_r} ->
            total = support + max_r

            "| #{pp} power, #{wp} water, #{ind} industrial, #{rh} road, #{com} commercial " <>
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
  defp residential_range(pp, wp, ind, rh, com) do
    sustainable =
      for r <- 1..40,
          city =
            city_with(
              power_plant: pp,
              water_plant: wp,
              industrial: ind,
              road_hub: rh,
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
      for type <- sorted_types(), not Enum.empty?(production_of(type)) do
        produced = production_of(type)

        # Iterated in the display-order @resources list rather than the raw map's
        # key order: a map's key order is a hash-seed artifact, not a decision
        # anyone made, and residential (labour + money, as of this task) is the
        # first production entry with two keys to expose that non-determinism.
        outputs =
          @resources
          |> Enum.filter(&Map.has_key?(produced, &1))
          |> Enum.map_join(", ", fn r -> "#{r} #{num(Map.fetch!(produced, r))}" end)

        "| `#{type}` | #{outputs} |"
      end

    non_producers =
      sorted_types()
      |> Enum.filter(&Enum.empty?(production_of(&1)))
      |> Enum.map_join(", ", &"`#{&1}`")

    # Commercial's money production means every type produces something now, so
    # there is no non-producer list to print — `Enum.empty?` sidesteps the dead
    # comparison `== %{}` would be (every production map is non-empty at the
    # type level too, which is what made that comparison a compiler warning).
    footer =
      if non_producers == "" do
        "Every type produces something."
      else
        "Produce nothing at all: #{non_producers}."
      end

    Enum.join(
      ["| type | produces |", "|---|---|"] ++ rows ++ ["", footer],
      "\n"
    )
  end

  defp consumption_block do
    header = "| type | " <> Enum.map_join(@resources, " | ", &"#{&1}") <> " |"
    rule = "|---|" <> String.duplicate("---|", length(@resources))

    rows =
      for type <- sorted_types() do
        consumption = Node.consumption(type)

        cells =
          Enum.map_join(@resources, " | ", fn r ->
            case Map.get(consumption, r) do
              nil -> "—"
              amount -> num(amount)
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

  # Scanned rather than restated, so a change to `status_for/1` moves the guide.
  defp status_thresholds do
    healths = Enum.map(0..1000, &(&1 / 10))

    {Enum.find(healths, &(Node.status_for(&1) == :online)),
     Enum.find(healths, &(Node.status_for(&1) == :degraded))}
  end

  defp tick_ms, do: Application.get_env(:armchair_metropolist, :tick_interval_ms, 1000)

  # --- helpers ------------------------------------------------------------

  defp sorted_types, do: Enum.sort(Node.types())
  defp production_of(type), do: Node.production(type)

  defp city_with(counts) do
    {city, _} =
      Enum.reduce(counts, {CityMap.new(40, 30), 0}, fn {type, n}, acc ->
        Enum.reduce(1..n//1, acc, fn _, {map, i} ->
          {CityMap.put_node(map, Node.new(rem(i, 40), div(i, 40), type)), i + 1}
        end)
      end)

    # Not the 500.0 grant. Over the 120-tick window a city whose income falls one
    # short of its upkeep drains the grant at 1/tick and survives all 120 ticks —
    # so the guide would certify a city that goes bankrupt on tick 501. Starting
    # broke measures the steady-state economy: income must cover upkeep every tick.
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

  # 120.0 reads as noise in a table; 120 does not. Keeps one decimal when it matters.
  defp num(value) when is_float(value) do
    if value == Float.round(value),
      do: value |> trunc() |> Integer.to_string(),
      else: to_string(value)
  end

  defp num(value), do: to_string(value)
end
