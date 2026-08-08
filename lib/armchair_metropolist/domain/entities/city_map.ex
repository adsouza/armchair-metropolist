defmodule ArmchairMetropolist.Domain.Entities.CityMap do
  @moduledoc "The city grid and the infrastructure placed on it."

  alias ArmchairMetropolist.Domain.Entities.Node

  @type t :: %__MODULE__{
          width: pos_integer(),
          height: pos_integer(),
          min_x: integer(),
          min_y: integer(),
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
  # A field added here is also a hazard even when its values are plain floats, not just
  # when they are atoms: it is absent from every already-stored city, so decoding an old
  # snapshot yields a struct carrying only the keys it was written with, and any
  # `city_map.new_field` raises `KeyError` on hydrate rather than reading a default. Two
  # defaulting paths cover this independently: `SnapshotVocabulary.modernize/1` supplies
  # the default as part of decoding, and `CityEngine.normalize_city_map/1` merges
  # whatever comes out of that onto a fresh `%CityMap{}` on load. The committed fixtures
  # are what prove the first of those still works — see `waste_stock`, added 2026-08-07.
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

  # The grid a new city starts on. A city opens two more rows and columns whenever more
  # than 70% of its cells are occupied, up to `@max_size`.
  #
  # Referenced by `defstruct` below rather than restated there. `CityEngine`'s
  # `normalize_city_map/1` merges every decoded snapshot onto a fresh `%CityMap{}`, so the
  # struct defaults are what a stored city inherits for any field it lacks — exactly the
  # split the `@opening_grant` comment above describes. A literal in `defstruct` beside a
  # different value here desyncs them on a path only cold loads exercise.
  @initial_size 2

  # Growth stops here. This bounds the data structure, not the game: reaching a 32x32
  # takes 631 blocks, some 9,465 in construction costs, far past anything a player reaches.
  # It also keeps every stored 40x30 city off the ladder, since 40 exceeds it.
  @max_size 32

  # The occupancy that opens a new pair of rows, as a ratio rather than a float, so the
  # trigger is integer arithmetic and never a float comparison.
  #
  # 70% and not 80%: at 80% the boundary on a 2x2 is 3.2, so the starter grid alone had to
  # be completely full before it would open. At 70% no size on the ladder does.
  @fill_numerator 7
  @fill_denominator 10

  # `min_x`/`min_y` default to 0, not `-@initial_size` or anything else — 0 is what a
  # fresh 2x2 city has always meant (its window already ran 0..1 on both axes), and
  # `CityEngine.normalize_city_map/1` merges every decoded snapshot onto a fresh
  # `%CityMap{}`, so a city stored before this field existed inherits exactly that
  # meaning: an origin that has never moved. No new atom is introduced — both values
  # are plain integers — so `Infrastructure.Persistence.SnapshotVocabulary` needs no
  # entry for them, unlike a field whose values are atoms defined outside this module.
  # The next reader will ask, so it is worth saying even though nothing here forces it.
  defstruct width: @initial_size,
            height: @initial_size,
            min_x: 0,
            min_y: 0,
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
  Create a new city on the starting grid.

  The one definition of what a new city is. `new/2` exists for fixtures that want a grid
  large enough that capacity never binds; it is *not* how a stored city is rebuilt, which
  goes through `CityEngine.normalize_city_map/1` and the struct defaults.
  """
  @spec new() :: t()
  def new, do: new(@initial_size, @initial_size)

  @doc """
  Open one more ring — a cell on every side — if the grid is more than 70% occupied,
  else return `map`.

  **The window extends; node coordinates never move.** `grow_if_crowded/1` widens the
  grid by shifting `min_x`/`min_y` down by one and adding two to `width`/`height`, so
  the window gains a cell on the left and top as well as the right and bottom. `nodes`
  is not touched — not rebuilt, not re-keyed. A node placed at `(3, 4)` is still at
  `(3, 4)` after any number of growths; only the *window* it sits inside grows around
  it, and that window's origin can go negative.

  That is load-bearing, not incidental. A click carries `phx-value-x` / `phx-value-y`
  baked into the DOM at render time, and the browser's DOM is stale for a full round
  trip after a growth, so commands composed against the old grid keep arriving
  afterwards. Because a node's coordinates never change, `(3, 4)` names the same cell
  before and after and those commands are still correct.

  **Do not re-key nodes to recentre them** — the tempting alternative, where growth
  moves every node so `(0, 0)` becomes `(1, 1)`. It reintroduces exactly the hazard
  `docs/superpowers/specs/2026-08-08-ring-growth-grid-design.md` (§9, "Why growth is
  anchored and not centred") measured for a plain anchored-vs-centred choice: the old
  and new coordinate sets overlap, so a stale click would not fail, it would resolve
  to a *different* cell and demolish the wrong block. That analysis is why growth used
  to be anchored at the origin outright, trading away centring to avoid the hazard.
  Extending the window is what recovers centring without it: the re-keying that
  analysis warns against is exactly what this function does not do. A re-keying
  variant would need a generation token on every coordinate-addressed command to
  detect the staleness; this one needs nothing, because no node ever moves.
  """
  @spec grow_if_crowded(t()) :: t()
  def grow_if_crowded(map) do
    if max(map.width, map.height) < @max_size and crowded?(map) do
      %{
        map
        | min_x: map.min_x - 1,
          min_y: map.min_y - 1,
          width: map.width + 2,
          height: map.height + 2
      }
    else
      map
    end
  end

  defp crowded?(map) do
    map_size(map.nodes) * @fill_denominator >
      @fill_numerator * map.width * map.height
  end

  @doc """
  Discard this city and start a new one.

  Tick 0, no nodes, the treasury back to `opening_grant/0`, and the grid back to the
  starting size — delegating to `new/0` rather than resetting fields by hand, so there is
  exactly one definition of what a new city is and this cannot drift from it.

  The grant has to come back. A collapsed city's treasury has drained to zero and the
  cheapest block costs 15, so a wipe that cleared the grid and left the balance alone would
  trade one dead end for another.
  """
  @spec reset(t()) :: t()
  def reset(_map), do: new()

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

  Window-relative, not origin-anchored: valid range is `min_x <= x < min_x + width`
  and `min_y <= y < min_y + height`. A city that has never grown has `min_x` and
  `min_y` at 0, so this reduces to the old `0 <= x < width` check exactly; a grown
  city's window can start at a negative coordinate.
  """
  def in_bounds?(map, x, y) do
    x >= map.min_x and x < map.min_x + map.width and
      y >= map.min_y and y < map.min_y + map.height
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
