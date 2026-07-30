defmodule ArmchairMetropolist.CityGenerators do
  @moduledoc "StreamData generators for property-based domain tests."

  import StreamData
  import ExUnitProperties, only: [gen: 2]

  alias ArmchairMetropolist.Domain.Entities.{CityMap, Node}

  def node_type, do: member_of(Node.types())

  def health, do: float(min: 0.0, max: 100.0)

  @doc "A city on a small grid with 0..12 nodes at distinct coordinates."
  def city do
    gen all width <- integer(6..12),
            height <- integer(6..12),
            coords <-
              uniq_list_of(tuple({integer(0..5), integer(0..5)}), max_length: 12),
            types <- list_of(node_type(), length: length(coords)),
            healths <- list_of(health(), length: length(coords)) do
      [coords, types, healths]
      |> Enum.zip()
      |> Enum.reduce(CityMap.new(width, height), fn {{x, y}, type, h}, acc ->
        node = %Node{Node.new(x, y, type) | health: h, status: Node.status_for(h)}
        CityMap.put_node(acc, node)
      end)
    end
  end
end
