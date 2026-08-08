defmodule ArmchairMetropolistWeb.SimulatorLiveGridTest do
  use ArmchairMetropolistWeb.SimulatorLiveCase

  describe "grid geometry" do
    # Cell size is `min(128, max(24, div(768, max(width, height))))`. Each case below kills
    # a different clamp, and the assignment of case to clamp is not interchangeable:
    #
    #   2x2 -> 128 and 4x4 -> 128 kill the *ceiling*: without `min/2` they are 384 and 192.
    #   6x6 -> 128 kills nothing, because div(768, 6) is exactly 128. Kept as a boundary
    #     case; it is as blind to the ceiling as 8x8 is.
    #   40x30 -> 24 and 20x40 -> 24 both kill the *floor*: div(768, 40) is 19 for either, so
    #     dropping `max/2` returns 19 from both. None of the square sizes can — dropping the
    #     floor leaves 2x2, 4x4, 6x6, 8x8 and 32x32 all unchanged.
    #   20x40 -> 24 kills `div(768, width)` in place of `max(width, height)`, which gives 38.
    test "cell size shrinks as the grid grows, clamped at both ends" do
      assert SimulatorLive.cell_size(2, 2) == 128
      assert SimulatorLive.cell_size(4, 4) == 128
      assert SimulatorLive.cell_size(6, 6) == 128
      assert SimulatorLive.cell_size(8, 8) == 96
      assert SimulatorLive.cell_size(32, 32) == 24
    end

    test "the floor keeps a legacy 40x30 grid at today's cell size" do
      assert SimulatorLive.cell_size(40, 30) == 24
    end

    test "cell size is driven by the longer axis" do
      assert SimulatorLive.cell_size(20, 40) == 24
    end

    # Tagged, deliberately. `@tag treasury:` seeds an explicit `CityMap.new(40, 30)`, which
    # is what this test's name claims it is testing. Untagged it would ride the fresh-city
    # path, and Task 6 makes that a 2x2 and adds a test asserting 256px on the same path —
    # the two would contradict each other and one would have to be deleted.
    @tag treasury: 400.0
    test "a stored 40x30 city renders at exactly today's size", %{conn: conn} do
      # Pins "no existing city changes appearance". 40 * 24 by 30 * 24.
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s{[style*="width: 960px; height: 720px;"]})

      # Every existing cell_count assertion elsewhere in this file is on a square grid
      # (2x2 or 4x4), so a mutation swapping `city_map.height` for `city_map.width` in
      # `assign_grid/2`'s comprehension survives the rest of the suite untouched. On this
      # non-square 40x30 city that mutation renders 40 * 40 = 1600 background cells
      # instead of the correct 40 * 30 = 1200 — 400 extra clickable divs whose clicks are
      # silently refused `:out_of_bounds`.
      assert cell_count(render(view)) == 1200
    end
  end

  describe "the view resizes when the grid grows" do
    test "an already-streamed node's geometry follows the new cell size", %{conn: conn} do
      # 6x6 -> 8x8 and NOT 2x2 -> 4x4: cell size is 128 at 2x2, 4x4 and 6x6, so across those
      # growths correct and broken code emit byte-identical geometry. 6x6 -> 8x8 is the first
      # growth that moves it, 128 -> 96.
      #
      # The node is streamed by {:city_node_placed, ...} *before* the growth, deliberately.
      # An earlier version of this test introduced it through the growth payload itself, so
      # a handler that did not re-stream made the node *absent* rather than *stale* -- it
      # could not tell those two failure modes apart, and stale geometry is the one that
      # matters. A LiveView stream does not re-render existing entries when an assign
      # changes (`LiveStream`'s Enumerable reduces over pending inserts only), so without an
      # explicit re-stream this node keeps `width: 128px` on a 96px grid.
      {:ok, view, _html} = live(conn, ~p"/")

      broadcast({:city_grew, CityMap.new(6, 6)})
      broadcast({:city_node_placed, Node.new(1, 1, :park)})
      assert rendered_node(render(view), "1:1") =~ "width: 128px"

      eight = %{CityMap.put_node(CityMap.new(6, 6), Node.new(1, 1, :park)) | width: 8, height: 8}
      broadcast({:city_grew, eight})

      html = rendered_node(render(view), "1:1")
      assert html =~ "width: 96px"
      assert html =~ "left: 96px"
      refute html =~ "128px"
    end

    test "the background grid and the banner follow too", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      broadcast({:city_grew, CityMap.new(4, 4)})

      # 16 cells, so :grid_cells was recomputed and not merely :width reassigned.
      assert cell_count(render(view)) == 16
      assert has_element?(view, ~s{[style*="width: 512px; height: 512px;"]})
    end

    @tag :stalled_city
    test "the collapse banner is as wide as the grown grid", %{conn: conn} do
      # A 40x30 stalled city (cell 24, banner 960px) broadcast straight to 8x8. Correct code
      # gives 8 * 96 = 768; a mutant that reassigns :width without :cell_size keeps cell 24
      # and gives 8 * 24 = 192. Separated either way -- but note the mutant's figure is 192,
      # not 1024: there is no 6x6 step here, so :cell_size never held 128.
      {:ok, view, _html} = live(conn, ~p"/")

      broadcast({:city_grew, %{CityMap.new(8, 8) | nodes: stalled_city(0.0).nodes}})

      assert has_element?(view, ~s{#collapse-banner[style*="width: 768px"]})
    end

    @tag :stalled_tiny_city
    test "the collapse banner is as wide as the starting grid", %{conn: conn} do
      # Pins spec section 3's measured relationship at the smallest grid the game renders:
      # 2 * 128 = 256px, which is what the `:locked` headline's 245px two-line threshold
      # bought. If this reads 192px, someone set @max_cell back to 96.
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s{#collapse-banner[style*="width: 256px"]})
    end

    test "a reset takes the grid back to 2x2", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      broadcast({:city_grew, CityMap.new(12, 12)})
      assert has_element?(view, ~s{[style*="width: 768px; height: 768px;"]})

      broadcast({:city_reset, CityMap.new()})

      # 2 * 128. Before this change the reset handler cleared the stream and left the grid
      # assigns alone, which was correct only while a reset preserved its grid.
      assert has_element?(view, ~s{[style*="width: 256px; height: 256px;"]})
      assert cell_count(render(view)) == 4
    end

    test "a brand new city starts on the 2x2 grid", %{conn: conn} do
      # The fresh-mount counterpart to "the background grid and the banner follow too"
      # above: that test's 16-cell assertion guards the broadcast path (:grid_cells
      # recomputed from a {:city_grew, ...} message), but nothing guarded hydration
      # itself — a mount that sizes the container from the hydrated width while
      # computing :grid_cells from something else would still render 256x256 with the
      # wrong cell count, and nothing here would have gone red.
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s{[style*="width: 256px; height: 256px;"]})
      assert cell_count(render(view)) == 4
    end

    test "placing the third block grows the grid the player is looking at", %{conn: conn} do
      # Crosses the whole seam: real clicks -> ManageInfrastructure -> CityEngine's growth
      # detection -> the broadcast -> the view's handler. Every other growth test above
      # drives one side with a synthetic message, so the two sides could agree with each
      # other and both be wrong about the message they exchange.
      #
      # This crosses 2x2 -> 4x4, where cell_size is 128 on both sides of the growth, so it
      # proves the message name, the payload shape, :width, :height and :grid_cells cross
      # the seam correctly -- but not :cell_size, since correct and broken code emit
      # byte-identical geometry at this particular boundary. The test below drives the
      # first growth that actually moves cell size, 6x6 -> 8x8, through the same real-click
      # path.
      {:ok, view, _html} = live(conn, ~p"/")

      assert has_element?(view, ~s{[style*="width: 256px; height: 256px;"]})

      place(view, :residential, 0, 0)
      place(view, :residential, 1, 0)
      assert has_element?(view, ~s{[style*="width: 256px; height: 256px;"]})

      place(view, :residential, 0, 1)

      # 4 * 128: the third block crosses 70% of a 2x2, so the grid opens to 4x4 and the
      # cell size has not changed yet (128 up to 6x6).
      assert has_element?(view, ~s{[style*="width: 512px; height: 512px;"]})
      assert render(view) =~ ~s{id="0:1"}

      # A handler that resizes the container without recomputing :grid_cells would pass
      # everything above while still painting a 2x2's worth of background cells behind it.
      assert cell_count(render(view)) == 16
    end

    @tag :crowded_six_by_six
    test "a real click that grows 6x6 to 8x8 refreshes an already-placed node's geometry",
         %{conn: conn} do
      # The seam test above never drives a growth where cell size actually moves, since
      # cell_size is 128 at both 2x2 and 4x4 -- so it cannot tell correct code from a
      # handler that resizes the container but never re-streams the nodes on it. 6x6 -> 8x8
      # is the first growth that moves cell size (128 -> 96), and this is the real-click
      # version of it.
      {:ok, view, _html} = live(conn, ~p"/")

      # 6 * 128, and already at the ceiling clamp -- see cell_size/2.
      assert has_element?(view, ~s{[style*="width: 768px; height: 768px;"]})
      assert rendered_node(render(view), "0:0") =~ "width: 128px"

      place(view, :residential, 1, 4)

      # 8 * 96 happens to read the same 768px as before -- see the cell_size moduledoc
      # comment on the footprint holding "between 748px and 768px" across this whole
      # stretch of the ramp -- so this assertion alone cannot tell a real resize from a
      # handler that silently did nothing. The node assertion below is the part that
      # actually crosses the seam: it can only pass if CityEngine's growth detection fired,
      # broadcast the post-put map, and the view re-streamed every node at the new cell
      # size, rather than merely resizing the container around stale geometry.
      assert has_element?(view, ~s{[style*="width: 768px; height: 768px;"]})
      assert rendered_node(render(view), "0:0") =~ "width: 96px"
    end
  end
end
