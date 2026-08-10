defmodule ArmchairMetropolist.Domain.Entities.Node do
  @moduledoc "A single piece of placed city infrastructure."

  @type resource ::
          :power
          | :water
          | :waste
          | :traffic
          | :injuries
          | :disease
          | :crime
          | :labour
          | :money
  @type node_type ::
          :power_plant
          | :water_plant
          | :industrial
          | :transit_hub
          | :residential
          | :commercial
          | :park
          | :hospital
          | :police_station
          | :school
  @type status :: :online | :degraded | :offline

  @type t :: %__MODULE__{
          id: String.t(),
          x: non_neg_integer(),
          y: non_neg_integer(),
          type: node_type(),
          health: float(),
          status: status()
        }

  # This struct is persisted, and snapshots are decoded with `:safe` — which will
  # not create atoms. The node-type and status vocabularies below are interned only
  # because this module gets loaded first; see
  # Infrastructure.Persistence.SnapshotVocabulary, and update it if a new
  # atom-valued field draws its values from elsewhere.
  defstruct [:id, :x, :y, :type, :health, :status]

  # The resource vocabulary, in the order every reader should see it. Written out
  # rather than derived from the tables below: those are maps, and `Map.keys/1`
  # order is an implementation detail of the term, whereas this order is a display
  # decision the legend depends on.
  @resources [:power, :water, :waste, :traffic, :injuries, :disease, :crime, :labour, :money]

  # The status vocabulary. Must stay in step with `status_for/1`'s clauses;
  # the `statuses/0` test derives its expectation from that function so the
  # two cannot drift apart silently.
  @statuses [:online, :degraded, :offline]

  # Resources where a rising figure is bad. For these, a capacity-table entry is
  # *removal* capacity and a load-table entry is *emission* — `industrial`
  # processes 90 waste, a house emits 10.
  #
  # The numbers stay in the tables they are in today, and must. Capacity is
  # health-scaled and load never is, which is exactly the right asymmetry
  # here: a neglected incinerator processes less, a decaying house still emits full.
  # Moving industrial's 90 to the load table to make it "read as removal"
  # would unscale removal from health, and waste would become the one resource
  # neglect cannot punish.
  #
  # Written out rather than derived, for the same reason `@resources` is: this is a
  # design commitment, and a derivation would let a table edit silently change which
  # resources are bads. The *sign convention* is not here — that is presentation,
  # and it lives beside `signed/1` in the LiveView.
  @negative_resources [:waste, :traffic, :injuries, :disease, :crime]

  # Capacity tables — the health-scaled side of the ledger.
  @capacity_table %{
    power_plant: %{power: 120.0},
    water_plant: %{water: 100.0},
    industrial: %{waste: 90.0},
    transit_hub: %{traffic: 60.0},
    residential: %{labour: 5.0, money: 1.0},
    commercial: %{money: 30.0},
    park: %{waste: 8.0},
    hospital: %{injuries: 10.0, disease: 10.0},
    police_station: %{crime: 12.0},
    school: %{crime: 6.0}
  }

  # Load tables — the side that is never scaled by health.
  @load_table %{
    power_plant: %{water: 20.0, waste: 12.0, traffic: 3.0, labour: 1.0, money: 5.0},
    water_plant: %{power: 25.0, waste: 6.0, traffic: 2.0, money: 5.0, labour: 1.0},
    industrial: %{power: 40.0, water: 25.0, traffic: 8.0, labour: 12.0},
    transit_hub: %{power: 8.0, waste: 2.0, money: 4.0, labour: 2.0},
    residential: %{power: 15.0, water: 12.0, waste: 10.0, traffic: 6.0},
    commercial: %{power: 22.0, water: 8.0, waste: 14.0, traffic: 9.0, labour: 8.0},
    park: %{water: 18.0, traffic: 2.0, money: 3.0, labour: 1.0},
    hospital: %{power: 20.0, water: 15.0, waste: 10.0, traffic: 4.0, labour: 4.0, money: 6.0},
    police_station: %{
      power: 12.0,
      water: 6.0,
      waste: 4.0,
      traffic: 3.0,
      labour: 3.0,
      money: 5.0
    },
    school: %{
      power: 18.0,
      water: 12.0,
      waste: 8.0,
      traffic: 6.0,
      labour: 4.0,
      money: 8.0
    }
  }

  # What each type costs to build. A third table beside capacity and load, so
  # every price a player pays lives in one module.
  #
  # Ordered by the block's weight in the city, so the curve reads as
  # infrastructure-is-expensive. Whole numbers throughout — see `cost` in the tests: the
  # legend and the treasury line both truncate, so a fractional cost would render a
  # figure the engine does not charge.
  @construction_cost_table %{
    power_plant: 80.0,
    water_plant: 70.0,
    industrial: 60.0,
    transit_hub: 40.0,
    commercial: 40.0,
    park: 20.0,
    hospital: 100.0,
    police_station: 70.0,
    school: 120.0,
    residential: 15.0
  }

  # Flat across every type, and strictly below the cheapest construction cost. Flat
  # because teardown does not care what stood there; below the cheapest because putting a
  # block up is the larger undertaking.
  #
  # `node_test.exs` enforces that second property rather than trusting it: without the
  # test, a later balance patch dropping `residential` to 8 would silently make tearing
  # down the expensive option and nothing in the suite would notice.
  @demolition_cost 10.0

  @doc """
  Create a new node at the given coordinates with the given type.
  Starts at full health (100.0) and online status.
  """
  def new(x, y, type) do
    %__MODULE__{
      id: id(x, y),
      x: x,
      y: y,
      type: type,
      health: 100.0,
      status: :online
    }
  end

  @doc """
  Generate an id string from coordinates.
  Format is "x:y" where x and y are the coordinates.
  """
  def id(x, y) do
    "#{x}:#{y}"
  end

  @doc """
  Get the capacity table for a node type.
  Returns a map of resource => amount (float).
  """
  def capacity(node_type) do
    Map.fetch!(@capacity_table, node_type)
  end

  @doc """
  Get the load table for a node type.
  Returns a map of resource => amount (float).
  """
  def load(node_type) do
    Map.fetch!(@load_table, node_type)
  end

  @doc """
  What it costs to build one node of `node_type`.

  Raises `KeyError` for an unknown type, deliberately: callers validate the type before
  reaching here (see `UseCases.ManageInfrastructure.place/4`, where that clause ordering
  is load-bearing), and a silent default would let an unknown type be built for free.
  """
  @spec construction_cost(node_type()) :: float()
  def construction_cost(node_type) do
    Map.fetch!(@construction_cost_table, node_type)
  end

  @doc """
  What it costs to demolish a node, whatever its type.
  """
  @spec demolition_cost() :: float()
  def demolition_cost, do: @demolition_cost

  @doc """
  The cheapest block a player can put up.

  Derived from the table rather than written down again: the figure appears in the
  game-over copy, and a balance patch that reprices `residential` must move the
  sentence with it.
  """
  @spec cheapest_construction_cost() :: float()
  def cheapest_construction_cost, do: Enum.min(Map.values(@construction_cost_table))

  @doc """
  The cheapest thing a player can do at all — build the cheapest block, or demolish.

  This is the bankruptcy threshold: below it no command is affordable, so a frozen
  city holding less than this can never change again. Derived rather than pinned to
  `demolition_cost/0`, even though demolition is the cheaper of the two today and
  `node_test.exs` enforces that. Deriving means a balance patch that inverts them
  moves this figure too, instead of silently leaving a threshold naming the wrong
  lever.
  """
  @spec cheapest_action_cost() :: float()
  def cheapest_action_cost, do: min(@demolition_cost, cheapest_construction_cost())

  @doc """
  Determine the status of a node based on its health value.
  Uses half-open intervals:
  - :online when health >= 60.0
  - :degraded when 20.0 <= health < 60.0
  - :offline when health < 20.0
  """
  def status_for(health) do
    cond do
      health >= 60.0 -> :online
      health >= 20.0 -> :degraded
      true -> :offline
    end
  end

  @doc """
  Get the display signature of a node.
  Returns a tuple of {rounded_health, status}.
  """
  def display_signature(node), do: {round(node.health), node.status}

  @doc """
  List all node types.
  Derived from the capacity table keys to avoid duplication.
  """
  def types do
    Map.keys(@capacity_table)
  end

  @doc """
  List every resource the simulation tracks, in display order.

  The single source of truth for the vocabulary `t:resource/0` describes: the web
  legend renders one column per entry, and `Domain.Services.SimulationCalculator`
  is pinned against it so its baseline table cannot drift.
  """
  @spec resources() :: [resource()]
  def resources, do: @resources

  @doc """
  List every status a node can hold.

  The single source of truth for the vocabulary `t:status/0` describes, in the
  same way `resources/0` is for resources. The persistence vocabulary's
  coverage fixture is compared against it, so a status this list does not name
  cannot silently join (or leave) what snapshots may contain.
  """
  @spec statuses() :: [status()]
  def statuses, do: @statuses

  @doc """
  The resources where a rising figure is bad.

  A subset of `resources/0`. Consumers use this to decide a *display* sign: for a
  negative resource the legend shows `consumed - produced`, so `industrial` reads
  -90 because it removes 90 waste and a house reads +10 because it emits 10.
  """
  @spec negative_resources() :: [resource()]
  def negative_resources, do: @negative_resources

  @doc """
  Whether a rising figure in `resource` is bad.
  """
  @spec negative_resource?(resource()) :: boolean()
  def negative_resource?(resource), do: resource in @negative_resources

  @doc """
  Calculate the effective capacity of a node, scaled by its health.
  Capacity is scaled by (health / 100).
  """
  def effective_capacity(node) do
    base_capacity = capacity(node.type)
    health_fraction = node.health / 100.0

    Map.new(base_capacity, fn {resource, amount} ->
      {resource, amount * health_fraction}
    end)
  end
end
