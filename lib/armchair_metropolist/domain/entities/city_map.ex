defmodule ArmchairMetropolist.Domain.Entities.CityMap do
  @moduledoc "The city grid and the infrastructure placed on it."

  alias ArmchairMetropolist.Domain.Entities.Node

  @type t :: %__MODULE__{
          width: pos_integer(),
          height: pos_integer(),
          tick: non_neg_integer(),
          nodes: %{optional(String.t()) => Node.t()},
          money: float(),
          waste_stock: float()
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
  #
  # A new field is also a hazard even when its values are plain floats: payloads
  # written before it exist decode without the key, so any `city_map.new_field`
  # raises `KeyError` on hydrate. `SnapshotVocabulary.modernize/1` supplies the
  # default for those, and the committed fixtures are what prove it — see
  # `waste_stock`, added 2026-08-07.
  # The money a new city starts with, stated once. It used to appear twice — here and
  # again in `new/2` — and `CityEngine.normalize_city_map/1` merges a decoded snapshot
  # onto `%CityMap{}`, so this default is what an old city inherits while `new/2`'s
  # literal was what a fresh one got. Changing one and not the other desynced them on a
  # path only cold loads exercise.
  #
  # 400, sized to the *second* city rather than the first. The cheapest earning city is
  # 75 — one commercial, one park and one house, measured stable at +28/tick — and 150
  # bought that twice over, which is why it stood for a while. What 150 could not buy is
  # the next rung: there is no self-sustaining city between 95 and 260, and the 260 one
  # has to be built through a stretch with no commercial block in it, so nothing is
  # earning while it goes up. On 150 that opening is refused part-way, at the power
  # plant, with 37 in the bank.
  #
  # 400 covers the whole of it from the grant alone, which is what the guide's opening
  # sequence spends. The slack is reaction time, not luxury: every stage of that
  # sequence is fully supplied, but the treasury drains at up to 7 a tick while it is
  # half-built, so the grant is what a player spends instead of hurrying. Measured, 400
  # sustains that opening at up to 4 seconds per placement; see docs/PLAYING.md, "Your
  # second city", whose figures are generated and pinned by
  # `test/docs/playing_guide_test.exs`.
  #
  # Raising this is not a way to make the game more forgiving in general — the health
  # deadlines are decay rates and no balance buys them off. Measured: the naive opening,
  # which puts the commercial block up before the plants, collapses identically on 260,
  # 1000 and 2000. `:tick_interval_ms` is the knob on that axis.
  @opening_grant 400.0

  defstruct width: 40,
            height: 30,
            tick: 0,
            nodes: %{},
            money: @opening_grant,
            waste_stock: 0.0

  @doc """
  Create a new empty city map with the given dimensions.
  """
  def new(width, height) do
    %__MODULE__{
      width: width,
      height: height,
      tick: 0,
      nodes: %{}
    }
  end

  @doc """
  Discard this city and start a new one on the same grid.

  Tick 0, no nodes, and the treasury back to `opening_grant/0` — delegating to `new/2`
  rather than resetting fields by hand, so there is exactly one definition of what a new
  city is and this cannot drift from it.

  The grant has to come back. A collapsed city's treasury has drained to zero and the
  cheapest block costs 15, so a wipe that cleared the grid and left the balance alone
  would trade one dead end for another: an empty grid earns nothing, forever.
  """
  @spec reset(t()) :: t()
  def reset(map), do: new(map.width, map.height)

  @doc """
  The money a new city starts with.

  Public so tests and the playing-guide generator reference the figure instead of
  restating it. Six readers across four files pinned the old literal, and one of them
  pinned it *derived* — an assertion on 502.0, the grant plus two ticks of income, which
  a search for the grant's own value does not find.
  """
  @spec opening_grant() :: float()
  def opening_grant, do: @opening_grant

  @doc """
  Subtract `amount` from the city's treasury, flooring at zero.

  A one-line function rather than an inline `%{map | money: …}` so the floor-at-zero rule
  lives in the entity that owns the field. `ManageInfrastructure` refuses an unaffordable
  command, so the floor is unreachable through it — and that is the point: the clamp
  documents that a balance is never negative regardless of caller.
  """
  @spec debit(t(), float()) :: t()
  def debit(map, amount) do
    %{map | money: max(0.0, map.money - amount)}
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
