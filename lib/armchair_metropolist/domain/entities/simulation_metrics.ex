defmodule ArmchairMetropolist.Domain.Entities.SimulationMetrics do
  @moduledoc "Aggregate supply/demand and health figures for one tick."

  alias ArmchairMetropolist.Domain.Entities.CityMap
  alias ArmchairMetropolist.Domain.Entities.Node

  @typedoc """
  Two satisfaction figures, on two different bases. `satisfaction` is computed
  over `supplied + carried` — the balance-inclusive figure that drives health
  decay, the deficit notification and the *Tightest* line, all of which answer
  "what is damaging the city right now". `flow_satisfaction` is the same ratio
  computed over `supplied` alone, ignoring `carried` entirely — the figure the
  legend's totals cell renders, answering "is my per-tick economy balanced".
  Most resources carry nothing (`carried: 0.0`), so the two agree. Money and
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
          amenity: float(),
          amenity_marginal_labour: float(),
          amenity_labour: float(),
          housing_alive: boolean(),
          bankrupt: boolean(),
          stalled: boolean()
        }

  # A city with no parks has no amenity, so the identity multiplier and zero labour from it
  # are the correct values rather than filler, and a city with no nodes is not stalled. The
  # default exists because `build/2` has a dozen call sites in tests; the one production
  # caller, `Domain.Services.SimulationCalculator.metrics/1`, always passes real figures,
  # and a test on that wiring is what stops this default reaching a player.
  @default_derived %{
    amenity: 1.0,
    amenity_marginal_labour: 0.0,
    amenity_labour: 0.0,
    stalled: false
  }

  defstruct tick: 0,
            resources: %{},
            node_count: 0,
            avg_health: 0.0,
            offline_count: 0,
            by_type: %{},
            money: 0.0,
            waste_stock: 0.0,
            amenity: 1.0,
            amenity_marginal_labour: 0.0,
            amenity_labour: 0.0,
            housing_alive: false,
            bankrupt: false,
            stalled: false

  @doc """
  Build a SimulationMetrics struct from a city map, resource statistics and the city's
  derived figures.

  `derived` carries `:amenity` (the multiplier on labour supply), `:amenity_marginal_labour`
  (what one more park would add to it), `:amenity_labour` (what the *already placed*
  parks are contributing to it) and `:stalled` (whether the city has reached a health
  fixpoint). The amenity pair answers different questions and the legend shows both,
  stacked. All four are computed by `Domain.Services.SimulationCalculator`, which this
  module cannot call — `Domain` has `deps: []` — so they arrive as an argument rather
  than being derived here.
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
      by_type: build_by_type(nodes),
      money: city_map.money,
      waste_stock: city_map.waste_stock,
      amenity: Map.fetch!(derived, :amenity),
      amenity_marginal_labour: Map.fetch!(derived, :amenity_marginal_labour),
      amenity_labour: Map.fetch!(derived, :amenity_labour),
      housing_alive: housing_alive?(nodes),
      # Derived rather than a written-down `10.0`, for the same reason
      # `Node.cheapest_action_cost/0` itself is derived: so a balance patch to the
      # construction or demolition tables moves the threshold with it. No test here can
      # tell this call apart from a hardcoded copy of today's value — the two agree at
      # `10.0` and nothing in this module's test environment can make them diverge — so
      # the coverage that actually protects this line lives in `node_test.exs`, which
      # characterizes `cheapest_action_cost/0` against the tables directly.
      bankrupt: city_map.money < Node.cheapest_action_cost(),
      stalled: Map.fetch!(derived, :stalled)
    }
  end

  @doc """
  Whether this city can never change again.

  Both halves are needed and neither implies the other. `stalled` means the clock has
  stopped, but a stalled city holding money can still be rescued — one demolition is
  enough to take three dead houses back under the free baseline. `bankrupt` means no
  command is affordable, but a running city that is merely broke still earns.

  Defined here, once, rather than composed at each call site: the template and
  `docs/PLAYING.md` both describe this state and must not be able to disagree about it.
  """
  @spec game_over?(t()) :: boolean()
  def game_over?(%__MODULE__{stalled: stalled, bankrupt: bankrupt}), do: stalled and bankrupt

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
  defp build_by_type(nodes) do
    grouped = Enum.group_by(nodes, & &1.type)

    Map.new(Node.types(), fn type ->
      of_type = Map.get(grouped, type, [])

      {type,
       %{
         count: length(of_type),
         rated_capacity: scale(Node.capacity(type), length(of_type)),
         actual_capacity: sum_actual_capacity(type, of_type),
         load: scale(Node.load(type), length(of_type))
       }}
    end)
  end

  defp scale(table, count) do
    Map.new(table, fn {resource, amount} -> {resource, amount * count} end)
  end

  # Keyed off the type's *base* capacity table rather than the nodes, so the keys are
  # the same whether or not any are placed.
  defp sum_actual_capacity(type, nodes) do
    type
    |> Node.capacity()
    |> Map.new(fn {resource, _base} ->
      total =
        Enum.reduce(nodes, 0.0, fn node, acc ->
          acc + Map.get(Node.effective_capacity(node), resource, 0.0)
        end)

      {resource, total}
    end)
  end
end
