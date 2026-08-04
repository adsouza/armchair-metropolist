defmodule ArmchairMetropolist.Domain.Entities.Node do
  @moduledoc "A single piece of placed city infrastructure."

  @type resource :: :power | :water | :waste | :traffic | :labour | :money
  @type node_type ::
          :power_plant
          | :water_plant
          | :industrial
          | :transit_hub
          | :residential
          | :commercial
          | :park
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
  @resources [:power, :water, :waste, :traffic, :labour, :money]

  # Production tables (resource outputs)
  @production_table %{
    power_plant: %{power: 120.0},
    water_plant: %{water: 100.0},
    industrial: %{waste: 90.0},
    transit_hub: %{traffic: 60.0},
    residential: %{labour: 4.0, money: 1.0},
    commercial: %{money: 30.0},
    park: %{waste: 8.0}
  }

  # Consumption tables (resource inputs)
  @consumption_table %{
    power_plant: %{water: 20.0, waste: 12.0, traffic: 3.0},
    water_plant: %{power: 25.0, waste: 6.0, traffic: 2.0, money: 5.0},
    industrial: %{power: 40.0, water: 25.0, traffic: 8.0, labour: 12.0},
    transit_hub: %{power: 8.0, waste: 2.0, money: 4.0},
    residential: %{power: 15.0, water: 12.0, waste: 10.0, traffic: 6.0},
    commercial: %{power: 22.0, water: 8.0, waste: 14.0, traffic: 9.0, labour: 8.0},
    park: %{water: 18.0, traffic: 2.0, money: 3.0}
  }

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
  Get the production table for a node type.
  Returns a map of resource => amount (float).
  """
  def production(node_type) do
    Map.fetch!(@production_table, node_type)
  end

  @doc """
  Get the consumption table for a node type.
  Returns a map of resource => amount (float).
  """
  def consumption(node_type) do
    Map.fetch!(@consumption_table, node_type)
  end

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
  Derived from the production table keys to avoid duplication.
  """
  def types do
    Map.keys(@production_table)
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
  Calculate the effective production of a node, scaled by its health.
  Production is scaled by (health / 100).
  """
  def effective_production(node) do
    base_production = production(node.type)
    health_fraction = node.health / 100.0

    Map.new(base_production, fn {resource, amount} ->
      {resource, amount * health_fraction}
    end)
  end
end
