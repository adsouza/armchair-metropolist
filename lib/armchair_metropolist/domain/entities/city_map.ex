defmodule ArmchairMetropolist.Domain.Entities.CityMap do
  @moduledoc "The city grid and the infrastructure placed on it."

  alias ArmchairMetropolist.Domain.Entities.Node

  @type t :: %__MODULE__{
          width: pos_integer(),
          height: pos_integer(),
          tick: non_neg_integer(),
          nodes: %{optional(String.t()) => Node.t()},
          money: float()
        }

  # This struct is persisted, and snapshots are decoded with `:safe` — which will
  # not create atoms. Adding a field whose values are atoms defined outside this
  # module or Node, or making a new struct reachable from here, means updating
  # Infrastructure.Persistence.SnapshotVocabulary too. Miss it and saved cities are
  # discarded on load, only on cold VMs.
  #
  # A field added here is also absent from every already-stored city: decoding an
  # old snapshot yields a struct carrying only the keys it was written with, so
  # the new field must be defaulted on load (see CityEngine.normalize_city_map/1)
  # rather than assumed present.
  defstruct width: 40, height: 30, tick: 0, nodes: %{}, money: 500.0

  @doc """
  Create a new empty city map with the given dimensions.
  """
  def new(width, height) do
    %__MODULE__{
      width: width,
      height: height,
      tick: 0,
      nodes: %{},
      money: 500.0
    }
  end

  @doc """
  Check if the given coordinates are within the city bounds.
  Valid range is 0 <= x < width and 0 <= y < height.
  """
  def in_bounds?(map, x, y) do
    x >= 0 and x < map.width and y >= 0 and y < map.height
  end

  @doc """
  Get the node at the given coordinates, or nil if none exists.
  """
  def get_node(map, x, y) do
    Map.get(map.nodes, Node.id(x, y))
  end

  @doc """
  Check if a cell is occupied (contains a node).
  """
  def occupied?(map, x, y) do
    Map.has_key?(map.nodes, Node.id(x, y))
  end

  @doc """
  Add a node to the map at its coordinate position.
  """
  def put_node(map, node) do
    %{map | nodes: Map.put(map.nodes, Node.id(node.x, node.y), node)}
  end

  @doc """
  Remove the node at the given coordinates from the map.
  """
  def delete_node(map, x, y) do
    %{map | nodes: Map.delete(map.nodes, Node.id(x, y))}
  end

  @doc """
  Get a list of all nodes currently on the map.
  """
  def nodes(map) do
    Map.values(map.nodes)
  end
end
