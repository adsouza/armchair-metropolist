defmodule ArmchairMetropolistWeb.SimulatorLive do
  @moduledoc """
  The city dashboard: a 40x30 grid, live infrastructure, and live metrics.

  ## Rendering strategy

  The background grid (1,200 cells) is a plain comprehension computed once in
  `mount/3` and rendered from a static assign — it is never re-diffed on its
  own, since nothing in a tick ever changes `@grid_cells`. Placed
  infrastructure is tracked separately in `stream(:nodes, ...)`, keyed by the
  node's own `"x:y"` id via `dom_id: & &1.id`. Every tick only touches the
  handful of nodes that actually changed, so only those stream entries are
  patched — the grid underneath never moves. Nodes are absolutely positioned
  over the grid so the two layers stay independent.

  ## Where the figures come from

  `CityEngine.snapshot/1` returns full resource statistics at mount, before any tick —
  it computes them through `UseCases.SummarizeCity`, since `Infrastructure` may not
  reach `Domain.Services`. The engine also broadcasts `{:city_metrics, …}` after every
  successful place and demolish, so the legend's counts move on the click rather than
  on the next tick.
  """
  use ArmchairMetropolistWeb, :live_view

  alias ArmchairMetropolist.Domain.Entities.CityMap
  alias ArmchairMetropolist.Domain.Entities.Node
  alias ArmchairMetropolist.Infrastructure.Simulation.CityEngine

  @cell_size 24

  @impl true
  # Plug stores session keys as strings, so this matches "city_id" rather than the
  # atom the plug wrote. The second clause is the desktop target, which has no
  # browser session and one city.
  def mount(_params, %{"city_id" => city_id}, socket) when is_binary(city_id) do
    do_mount(city_id, socket)
  end

  def mount(_params, _session, socket) do
    do_mount(
      Application.get_env(:armchair_metropolist, :desktop_city_id) ||
        CityEngine.default_city_id(),
      socket
    )
  end

  defp do_mount(city_id, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ArmchairMetropolist.PubSub, CityEngine.topic(city_id))

      # Ties the city's lifetime to this connection. The engine monitors us, so a
      # closed tab, a crash and a navigation all look the same to it.
      :ok = CityEngine.attach(city_id, self())
    end

    {:ok, %{city_map: city_map, metrics: metrics}} = CityEngine.snapshot(city_id)

    socket = assign(socket, city_id: city_id)

    grid_cells =
      for y <- 0..(city_map.height - 1), x <- 0..(city_map.width - 1), do: {x, y}

    socket =
      socket
      |> assign(:width, city_map.width)
      |> assign(:height, city_map.height)
      |> assign(:grid_cells, grid_cells)
      |> assign(:metrics, metrics)
      |> assign(:node_types, Node.types())
      |> assign(:selected_type, List.first(Node.types()))
      |> assign(:legend_detail, true)
      |> assign(:cell_size, @cell_size)
      |> stream(:nodes, CityMap.nodes(city_map), dom_id: & &1.id)

    {:ok, socket}
  end

  @impl true
  def handle_event("select_type", %{"type" => type}, socket) do
    {:noreply, assign(socket, :selected_type, String.to_existing_atom(type))}
  end

  def handle_event("place", %{"x" => x, "y" => y}, socket) do
    x = String.to_integer(x)
    y = String.to_integer(y)

    case CityEngine.place(socket.assigns.city_id, x, y, socket.assigns.selected_type) do
      {:ok, node} -> {:noreply, stream_insert(socket, :nodes, node)}
      {:error, _reason} -> {:noreply, socket}
    end
  end

  def handle_event("demolish", %{"x" => x, "y" => y}, socket) do
    x = String.to_integer(x)
    y = String.to_integer(y)

    case CityEngine.demolish(socket.assigns.city_id, x, y) do
      {:ok, id} -> {:noreply, stream_delete_by_dom_id(socket, :nodes, id)}
      {:error, _reason} -> {:noreply, socket}
    end
  end

  def handle_event("toggle_legend_detail", _params, socket) do
    {:noreply, assign(socket, :legend_detail, not socket.assigns.legend_detail)}
  end

  @impl true
  def handle_info({:city_delta, delta}, socket) do
    socket =
      Enum.reduce(delta, socket, fn {_id, node}, acc -> stream_insert(acc, :nodes, node) end)

    {:noreply, socket}
  end

  def handle_info({:city_metrics, metrics}, socket) do
    {:noreply, assign(socket, :metrics, metrics)}
  end

  def handle_info({:city_node_placed, node}, socket) do
    {:noreply, stream_insert(socket, :nodes, node)}
  end

  def handle_info({:city_node_removed, id}, socket) do
    {:noreply, stream_delete_by_dom_id(socket, :nodes, id)}
  end

  @impl true
  # Placing and demolishing are the same gesture — a click on a square — because the
  # node div sits on top of its grid cell and swallows the cell's own click. Nothing on
  # screen distinguishes them, so both tooltips name the action they will perform;
  # without that, demolishing is undiscoverable. It also happens to be the only escape
  # from a death spiral, since a dead node keeps drawing its full demand (see
  # docs/PLAYING.md).
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <%!-- The chrome in Layouts.app already shows the wordmark, so rendering it
            again here just duplicated it. Kept as sr-only rather than deleted:
            the page still needs exactly one h1 for screen readers. --%>
      <h1 class="sr-only">Armchair Metropolist</h1>

      <%!-- No breakpoint here on purpose. `flex-wrap` plus `min-w-fit` on the aside
            lets the *content* decide: the sidebar sits beside the grid exactly while
            it fits and drops below when it does not. Measured by forcing `flexDirection`
            on the real inner div below and resizing the real viewport (not a clone —
            cheaper to validate and immune to a clone's own `fit-content`/`flex-wrap`
            quirks), confirmed at the boundary pixel, the switch happens at viewport
            1935 expanded and 1212 collapsed — with Metrics stacked. Those are the
            lower ends (`W_col`) of the windows the inner thresholds below sit inside.

            The old `min-[1450px]` committed to a side-by-side layout 181px before the
            matrix could fit in it, which is what produced the horizontal scrollbar
            inside the sidebar. A corrected constant would drift the moment a resource
            column or a longer type name changed the table; a derived threshold cannot. --%>
      <div class="flex flex-wrap items-start gap-4">
        <div
          class="relative shrink-0 border border-base-300"
          style={"width: #{@width * @cell_size}px; height: #{@height * @cell_size}px;"}
        >
          <div
            :for={{x, y} <- @grid_cells}
            class="absolute border border-base-200 cursor-pointer"
            style={cell_style(x, y, @cell_size)}
            phx-click="place"
            phx-value-x={x}
            phx-value-y={y}
            title={"place #{@selected_type} at #{x}:#{y}"}
          >
          </div>

          <div id="nodes" phx-update="stream">
            <div
              :for={{dom_id, node} <- @streams.nodes}
              id={dom_id}
              class={[
                "absolute flex cursor-pointer items-center justify-center text-[8px]",
                status_class(node.status)
              ]}
              style={cell_style(node.x, node.y, @cell_size)}
              phx-click="demolish"
              phx-value-x={node.x}
              phx-value-y={node.y}
              title={"#{node.id} · #{node.type} · #{node.status} (#{round(node.health)}%) — click to demolish"}
            >
              {short_label(node.type)}
            </div>
          </div>
        </div>

        <%!-- `min-w-fit` (min-width: fit-content) is the other half of the wrapping
              rule above: it stops this flex item being squeezed below its own content,
              so it wraps to the next line instead of shrinking. That is what makes the
              sidebar's horizontal scrollbar unreachable rather than merely unlikely.

              These classes must be written here, in source. Tailwind's JIT only emits
              what it finds in the templates, and neither `flex-wrap` nor `min-w-fit`
              appears anywhere else in this project. --%>
        <%!-- No `grow`. daisyUI styles `.table` as `width: 100%`, so the matrix is only
              as wide as this aside — and `grow` made the aside swallow its whole flex
              line. Alone on a line below the grid that is the full page width, which
              stretched a 757px matrix across 1681px and pushed Metrics off the end.
              The aside must never be wider than its content; the table's `100%` is then
              a fixpoint at the matrix's natural width. --%>
        <aside class="min-w-fit">
          <button
            id="toggle-legend-detail"
            type="button"
            class="btn btn-xs mb-2"
            phx-click="toggle_legend_detail"
            aria-expanded={to_string(@legend_detail)}
          >
            {if @legend_detail, do: "Hide detail", else: "Show detail"}
          </button>

          <%!-- Stacked while the sidebar is beside the grid; side by side once it has
                wrapped underneath, where the full page width is going spare.

                The `max-[Npx]` below is a constant, unlike the layout above, and that is a
                deliberate trade. It cannot be content-derived: the sidebar's own
                intrinsic width is what decides where it wraps, so a side-by-side inner
                row feeds back into that decision — a row raises the sidebar's own
                `fit-content` width and, with it, the viewport the sidebar needs to sit
                beside the grid (`W_row` below is always the larger of the two measured
                windows, for exactly this reason), putting the legend under the grid at
                every ordinary window size. Keeping the children stacked by default keeps
                the sidebar's intrinsic width at the matrix's own natural width (878px
                expanded) and the wrap threshold at the smaller `W_col`.

                **One threshold per state**, because the sidebar's width is what decides
                where it wraps and collapsing changes that width. A single constant is
                right in one state and wrong in the other — with only the expanded value,
                collapsing a wrapped legend moved it back beside the grid while Metrics
                stayed stubbornly alongside it.

                **Each threshold is the midpoint of a window, not a measured edge.** There
                are two wrap points per state, because the arrangement chosen here feeds
                back into the sidebar's own width: stacked, the sidebar is as wide as the
                matrix and fits beside the grid from viewport `W_col`; side by side it is
                a whole Metrics column wider and needs `W_row`. Any constant strictly
                inside `[W_col, W_row]` is self-consistent — at or above it the children
                stack and the sidebar fits beside the grid, below it they sit in a row and
                the sidebar has already dropped underneath. The window is exactly as wide
                as Metrics plus the gap.

                Measured by binary search on the live page (forcing `flexDirection` on the
                real inner div and resizing the real viewport, rather than a clone — cheaper
                to validate and immune to the clone's own `fit-content` quirks), then
                confirmed at the boundary pixel: expanded `[1935, 2084]`, collapsed
                `[1212, 1337]`. The midpoints below therefore absorb ±75px and ±63px of
                content drift before anything misbehaves.

                Re-measured when four resource columns became six: the collapsed table has
                no resource columns at all (both header and body cells are `:if={@detail}`),
                so its window barely moved, but the expanded matrix's two new columns pushed
                its window up by roughly 100px on both edges. Taking the midpoint is what
                makes this constant survive ordinary edits; re-measure only if Metrics, the
                grid, or the resource vocabulary changes size, and move the value to the new
                midpoint rather than to whichever edge you happened to measure.

                Tailwind v4 compiles `max-[N]` to `@media (width < N)`, exclusive, so N is
                the first viewport that should *not* get the row layout. --%>
          <div class={[
            "flex flex-col gap-4",
            if(@legend_detail, do: "max-[2010px]:flex-row", else: "max-[1275px]:flex-row")
          ]}>
            <%!-- Rendered unconditionally. Collapsing hides the resource *detail*, never
                  the legend: the type rows are the only way to choose what to place. --%>
            <.legend
              detail={@legend_detail}
              metrics={@metrics}
              node_types={@node_types}
              selected_type={@selected_type}
            />

            <%!-- A sibling of the legend, not a child of it. Metrics used to live inside
                  `legend/1` and so could not survive a collapse — the structural reason
                  the toggle hid them. --%>
            <.metrics metrics={@metrics} />
          </div>
        </aside>
      </div>
    </Layouts.app>
    """
  end

  # The resource columns are fixed and identical on every row, including where a type
  # does not touch a resource. Aligned columns are the feature: the question a player
  # has is "water is short, who is drinking it?", answered by reading one column down
  # all seven types. Per-row chips would be narrower and unreadable for that.
  #
  # The vocabulary itself belongs to the domain — `Node.resources/0` is the one list,
  # already in display order — so adding a resource grows this table by a column
  # rather than silently omitting it.
  attr :metrics, :map, required: true
  attr :node_types, :list, required: true
  attr :selected_type, :atom, required: true
  attr :detail, :boolean, required: true

  defp legend(assigns) do
    assigns = assign(assigns, :resources, Node.resources())

    ~H"""
    <%!-- No width classes here on purpose. The shrink-to-scroll behaviour lives on
          `<aside>` in `render/1`, the direct flex item of the row layout; this div is
          an ordinary block child of that aside, so `min-w-0` would be inert and
          `w-full`/`w-auto` would each resolve to the width it already takes. The
          duplicate class list only read as though it were doing the work. --%>
    <div>
      <%!-- "Legend" and not "Types": the toggle offers to hide the legend, the row ids
            are `legend-*`, and docs/PLAYING.md sends the player looking for a legend.
            The table's own `type` column header is caption enough for the rows. --%>
      <h2 class="font-semibold mb-2">Legend</h2>

      <div class="overflow-x-auto">
        <table class="table table-xs">
          <thead>
            <tr>
              <th class="text-left">type</th>
              <th class="text-right">#</th>
              <th :for={resource <- @resources} :if={@detail} class="text-right">{resource}</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={type <- @node_types}
              id={"legend-row-#{type}"}
              data-count={@metrics.by_type[type].count}
              class={type == @selected_type && "bg-primary/20"}
            >
              <td class="text-left">
                <%!-- A real button, not a clickable <tr>: the row must stay reachable
                      by keyboard and expose button semantics to assistive tech. --%>
                <button
                  type="button"
                  class="btn btn-ghost btn-xs w-full justify-start"
                  phx-click="select_type"
                  phx-value-type={type}
                  aria-pressed={to_string(type == @selected_type)}
                >
                  {type}
                </button>
              </td>
              <td data-cell={"#{type}-count"} class="text-right tabular-nums">
                {@metrics.by_type[type].count}
              </td>
              <.resource_cell
                :for={resource <- @resources}
                :if={@detail}
                type={type}
                resource={resource}
                stats={@metrics.by_type[type]}
              />
            </tr>
          </tbody>
          <tfoot :if={@detail}>
            <tr id="legend-totals">
              <%!-- Every figure in the cells below is named here. Without the last
                    term the percentage went unlabelled anywhere on screen. Terse
                    because the label shares a narrow row with six numeric columns.
                    "this tick" is load-bearing, not decoration: the percentage is
                    `flow_satisfaction`, which ignores money's carried balance, so
                    the label has to say *when* it is measuring rather than just
                    what — "met" alone would still promise the balance-aware figure
                    the cell no longer shows. --%>
              <th class="text-left" colspan="2">supplied/demanded · met this tick</th>
              <th
                :for={resource <- @resources}
                data-total={resource}
                class="text-right tabular-nums"
              >
                {totals_cell(@metrics.resources, resource)}
              </th>
            </tr>
          </tfoot>
        </table>
      </div>

      <%!-- Hidden with the totals row it explains — and not only for tidiness. A long
            line of prose sets this sidebar's `fit-content`, so left visible it holds the
            collapsed sidebar at 437px instead of 127px, and collapsing would reclaim
            almost nothing. Anything added here must stay short or wrappable. --%>
      <p :if={@detail} class="mt-1 text-xs opacity-60">
        Totals include the free baseline of 40 for power, water, waste and traffic, which
        belongs to no type. Labour and money have no free baseline.
      </p>
    </div>
    """
  end

  # Always on screen, in both legend states. Tick, nodes, average health and offline
  # count, plus the tightest resource — which otherwise appears only in the totals row,
  # and that row is exactly what collapsing hides. `docs/PLAYING.md` calls the lowest
  # satisfaction the only number that matters, so it is the figure that has to survive.
  attr :metrics, :map, required: true

  defp metrics(assigns) do
    assigns = assign(assigns, :tightest, tightest_resource(assigns.metrics.resources))

    ~H"""
    <div>
      <h2 class="font-semibold mb-2">Metrics</h2>
      <p id="metrics-tick">Tick: {@metrics.tick}</p>
      <p id="metrics-nodes">Nodes: {@metrics.node_count}</p>
      <p id="metrics-health">Avg health: {Float.round(@metrics.avg_health, 1)}</p>
      <p id="metrics-offline">Offline: {@metrics.offline_count}</p>
      <p id="metrics-treasury">Treasury: {round(@metrics.money)}</p>
      <p :if={@tightest} id="metrics-tightest">{tightest_text(@tightest)}</p>
    </div>
    """
  end

  # `resources` is populated from mount, so the empty clause is ordinary defensiveness
  # rather than a state the app reaches. Rounded to whole percent: this is a glance
  # figure, and the totals row carries the precise one when the legend is expanded.
  defp tightest_resource(resources) when map_size(resources) == 0, do: nil

  defp tightest_resource(resources) do
    {resource, stats} = Enum.min_by(resources, fn {_resource, stats} -> stats.satisfaction end)
    percent = round(stats.satisfaction * 100)

    # Naming a resource only means something when one is actually behind. With every
    # resource fully supplied the minimum is a six-way tie and `min_by` breaks it
    # arbitrarily, so an untouched city read "Tightest: traffic 100%" — true, and
    # misleading about traffic.
    #
    # The test is on `percent`, not on the raw float: satisfaction 0.999 renders as
    # 100%, and "tightest: water 100%" is the same noise. Compare at the precision the
    # player actually sees.
    if percent == 100, do: :all_supplied, else: {resource, percent}
  end

  defp tightest_text(:all_supplied), do: "All resources supplied"
  defp tightest_text({resource, percent}), do: "Tightest: #{resource} #{percent}%"

  # Two figures, stacked. Width is the scarce dimension in this sidebar and height is
  # not — measured, stacking costs 0px of width where an inline `+360 (+120 ea)` costs
  # 111px, which would push the wrap threshold from 1711 to ~1822 and drop the legend
  # below the grid at an ordinary window size.
  attr :type, :atom, required: true
  attr :resource, :atom, required: true
  attr :stats, :map, required: true

  defp resource_cell(assigns) do
    assigns =
      assigns
      |> assign(:marginal, marginal_cell(assigns.type, assigns.resource))
      |> assign(:total, total_cell(assigns.stats, assigns.resource))

    ~H"""
    <td data-cell={"#{@type}-#{@resource}"} class="text-right tabular-nums">
      <%!-- Position and weight already separate these two, so the colour is reinforcing
            rather than load-bearing — the cell still reads without it.

            A different hue per theme, which is forced rather than chosen: no single
            accent clears WCAG AA against both backgrounds. Measured, `secondary` is
            4.55 on the light theme but only 4.01 on the dark even after that theme's
            base-100 was darkened, while `info` is 4.69 on the dark and just 3.58 on
            the light. These are 11px data figures, so AA is the bar. --%>
      <div class="text-secondary dark:text-info">{@marginal}</div>
      <div :if={@total} class="font-semibold">{@total}</div>
    </td>
    """
  end

  # What one more block of this type would do — the figure a player needs to choose what
  # to place, and the one the old cell never showed: everything was scaled by the count,
  # so a type with none placed read "+0" in every column.
  #
  # Rated, deliberately. A newly placed node starts at full health, so its contribution
  # *is* its rated figure. Taken from the domain's own tables rather than from `by_type`
  # because this is a property of the type, fixed, not of the current city.
  defp marginal_cell(type, resource) do
    produced = Map.get(Node.production(type), resource)
    consumed = Map.get(Node.consumption(type), resource)

    if is_nil(produced) and is_nil(consumed) do
      "—"
    else
      signed((produced || 0.0) - (consumed || 0.0))
    end
  end

  # A missing key means the type does not interact with the resource at all, which reads
  # differently from a net of zero — hence the em dash rather than "0".
  #
  # Rated and actual are shown together only when they differ, so a healthy city reads
  # cleanly and divergence is what draws the eye.
  #
  # `nil` rather than a string when nothing is placed: the total of nothing is zero and
  # saying so is noise, and the per-block line above already carries the row's meaning.
  defp total_cell(%{count: 0}, _resource), do: nil

  defp total_cell(stats, resource) do
    produced = Map.get(stats.rated_production, resource)
    actual = Map.get(stats.actual_production, resource)
    consumed = Map.get(stats.consumption, resource)

    cond do
      is_nil(produced) and is_nil(consumed) ->
        nil

      is_nil(produced) ->
        signed(-consumed)

      true ->
        rated_net = produced - (consumed || 0.0)
        actual_net = actual - (consumed || 0.0)

        # Compared as displayed rather than as floats: production scales continuously
        # with health, so most of the time the two differ by a fraction of a unit that
        # `signed/1` then rounds away, and the arrow would point from a number to
        # itself. `SimulationCalculator` makes the same choice one layer down, comparing
        # `{round(health), status}` so sub-pixel drift never surfaces.
        if round(rated_net) == round(actual_net),
          do: signed(rated_net),
          else: "#{signed(rated_net)} → #{signed(actual_net)}"
    end
  end

  # `resources` is populated from mount via SummarizeCity, so there is no empty-map
  # case to guard here beyond ordinary defensiveness.
  defp totals_cell(resources, resource) do
    case Map.get(resources, resource) do
      nil ->
        "—"

      stats ->
        # `flow_satisfaction`, not `satisfaction`: the two numbers shown are supplied
        # and demanded, both flow-only, so the percentage beside them has to be
        # computed on that same basis or it stops being derivable from what's on
        # screen. For money, `satisfaction` also counts the treasury and would make
        # this cell contradict its own two halves (13/23 while reading 100%).
        "#{round(stats.supplied)}/#{round(stats.demanded)} · " <>
          "#{Float.round(stats.flow_satisfaction * 100, 1)}%"
    end
  end

  defp signed(value) do
    rounded = round(value)
    if rounded > 0, do: "+#{rounded}", else: to_string(rounded)
  end

  defp cell_style(x, y, cell_size) do
    "left: #{x * cell_size}px; top: #{y * cell_size}px; width: #{cell_size}px; height: #{cell_size}px;"
  end

  defp status_class(:online), do: "bg-success/70"
  defp status_class(:degraded), do: "bg-warning/70"
  defp status_class(:offline), do: "bg-error/70"

  defp short_label(type) do
    type
    |> Atom.to_string()
    |> String.split("_")
    |> Enum.map_join("", &String.first/1)
    |> String.upcase()
  end
end
