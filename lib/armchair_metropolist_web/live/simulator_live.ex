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

  `CityEngine.snapshot/0` returns full resource statistics at mount, before any tick —
  it computes them through `UseCases.SummarizeCity`, since `Infrastructure` may not
  reach `Domain.Services`. The engine also broadcasts `{:city_metrics, …}` after every
  successful place and demolish, so the legend's counts move on the click rather than
  on the next tick.
  """
  use ArmchairMetropolistWeb, :live_view

  alias ArmchairMetropolist.Domain.Entities.CityMap
  alias ArmchairMetropolist.Domain.Entities.Node
  alias ArmchairMetropolist.Infrastructure.Simulation.CityEngine

  @topic "city_simulation"
  @cell_size 24

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(ArmchairMetropolist.PubSub, @topic)
    end

    {:ok, %{city_map: city_map, metrics: metrics}} = CityEngine.snapshot()

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

    case CityEngine.place(x, y, socket.assigns.selected_type) do
      {:ok, node} -> {:noreply, stream_insert(socket, :nodes, node)}
      {:error, _reason} -> {:noreply, socket}
    end
  end

  def handle_event("demolish", %{"x" => x, "y" => y}, socket) do
    x = String.to_integer(x)
    y = String.to_integer(y)

    case CityEngine.demolish(x, y) do
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
            it fits and drops below when it does not. Measured, the switch happens at
            1632px expanded (960 grid + 16 gap + 655 matrix) and ~1103px collapsed.

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
              <td
                :for={resource <- @resources}
                :if={@detail}
                data-cell={"#{type}-#{resource}"}
                class="text-right tabular-nums"
              >
                {net_cell(@metrics.by_type[type], resource)}
              </td>
            </tr>
          </tbody>
          <tfoot :if={@detail}>
            <tr id="legend-totals">
              <%!-- Every figure in the cells below is named here. Without the last
                    term the percentage went unlabelled anywhere on screen. Terse
                    because the label shares a narrow row with four numeric columns. --%>
              <th class="text-left" colspan="2">supplied/demanded · met</th>
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
        Totals include the free baseline of 40 per resource, which belongs to no type.
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
    <div class="mt-4">
      <h2 class="font-semibold mb-2">Metrics</h2>
      <p id="metrics-tick">Tick: {@metrics.tick}</p>
      <p id="metrics-nodes">Nodes: {@metrics.node_count}</p>
      <p id="metrics-health">Avg health: {Float.round(@metrics.avg_health, 1)}</p>
      <p id="metrics-offline">Offline: {@metrics.offline_count}</p>
      <p :if={@tightest} id="metrics-tightest">
        Tightest: {elem(@tightest, 0)} {elem(@tightest, 1)}%
      </p>
    </div>
    """
  end

  # `resources` is populated from mount, so the empty clause is ordinary defensiveness
  # rather than a state the app reaches. Rounded to whole percent: this is a glance
  # figure, and the totals row carries the precise one when the legend is expanded.
  defp tightest_resource(resources) when map_size(resources) == 0, do: nil

  defp tightest_resource(resources) do
    {resource, stats} = Enum.min_by(resources, fn {_resource, stats} -> stats.satisfaction end)
    {resource, round(stats.satisfaction * 100)}
  end

  # A missing key means the type does not interact with the resource at all, which reads
  # differently from a net of zero — hence the em dash rather than "0".
  #
  # Rated and actual are shown together only when they differ, so a healthy city reads
  # cleanly and divergence is what draws the eye.
  defp net_cell(stats, resource) do
    produced = Map.get(stats.rated_production, resource)
    actual = Map.get(stats.actual_production, resource)
    consumed = Map.get(stats.consumption, resource)

    cond do
      is_nil(produced) and is_nil(consumed) ->
        "—"

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
        "#{round(stats.supplied)}/#{round(stats.demanded)} · " <>
          "#{Float.round(stats.satisfaction * 100, 1)}%"
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
