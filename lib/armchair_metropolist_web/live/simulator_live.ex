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
  alias ArmchairMetropolist.Domain.Entities.SimulationMetrics
  alias ArmchairMetropolist.Infrastructure.Simulation.CityEngine

  @cell_size 24

  @impl true
  # Checked before the session, deliberately. The desktop target's window still
  # loads its page through the same :browser pipeline as the server target — so
  # EnsureCityId (ensure_city_id.ex) still runs and still puts a real, random
  # city_id into the desktop's session on every launch. A clause ordered
  # session-first therefore always matched there too, and :desktop_city_id was
  # never read: harmless functionally, since FileSnapshotStore ignores whatever id
  # it is given, but it meant the desktop rendered a re-entry code (below) that
  # changed every launch and addressed nothing a single-user app could use. Checking
  # the application env first is what makes Desktop.Config's pin take effect at all.
  def mount(_params, session, socket) do
    case Application.get_env(:armchair_metropolist, :desktop_city_id) do
      nil -> mount_from_session(session, socket)
      city_id -> do_mount(city_id, socket, show_reentry?: false)
    end
  end

  # Plug stores session keys as strings, so this matches "city_id" rather than the
  # atom the plug wrote.
  defp mount_from_session(%{"city_id" => city_id}, socket) when is_binary(city_id) do
    do_mount(city_id, socket, show_reentry?: true)
  end

  defp mount_from_session(_session, socket) do
    # A server-target client that presented no session — a socket opened directly at
    # /live/websocket, where the :browser pipeline and therefore EnsureCityId never
    # ran — gets a fresh id rather than a shared constant. A LiveView cannot write the
    # session, so this city lasts only as long as the connection; that is the right
    # trade against the alternative, which is every such client silently landing in one
    # shared city and editing each other's work. That was the bug this whole change
    # exists to remove, and a constant here would have preserved it in a corner.
    do_mount(ArmchairMetropolistWeb.CityCode.generate(), socket, show_reentry?: true)
  end

  defp do_mount(city_id, socket, opts) do
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
      # False only on the desktop target (see mount/3): a recovery code the desktop
      # cannot use — there is no "elsewhere" to return to it from, and it would
      # change on every launch — is worse than none.
      |> assign(:show_reentry?, Keyword.fetch!(opts, :show_reentry?))
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
    type = socket.assigns.selected_type

    case CityEngine.place(socket.assigns.city_id, x, y, type) do
      {:ok, node} ->
        {:noreply, stream_insert(socket, :nodes, node)}

      {:error, :insufficient_funds} ->
        {:noreply, put_flash(socket, :error, unaffordable(type, socket.assigns.metrics.money))}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  def handle_event("demolish", %{"x" => x, "y" => y}, socket) do
    x = String.to_integer(x)
    y = String.to_integer(y)

    case CityEngine.demolish(socket.assigns.city_id, x, y) do
      {:ok, id} ->
        {:noreply, stream_delete_by_dom_id(socket, :nodes, id)}

      {:error, :insufficient_funds} ->
        {:noreply,
         put_flash(socket, :error, unaffordable_demolition(socket.assigns.metrics.money))}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  def handle_event("wipe", _params, socket) do
    :ok = CityEngine.reset(socket.assigns.city_id)

    {:noreply, stream(socket, :nodes, [], reset: true)}
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

  def handle_info(:city_reset, socket) do
    {:noreply, stream(socket, :nodes, [], reset: true)}
  end

  @impl true
  # Placing and demolishing are the same gesture — a click on a square — because the
  # node div sits on top of its grid cell and swallows the cell's own click. Nothing on
  # screen distinguishes them, so both tooltips name the action they will perform —
  # though *either* may name one the treasury refuses: a placement when the balance is
  # under the type's cost, a demolition when it is under the flat fee. The dimmed legend
  # row and the refusal flash cover that instead; without the naming, demolishing is
  # undiscoverable. It also happens to be the only way to reduce demand,
  # since a dead node keeps drawing its full demand (see docs/PLAYING.md).
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <%!-- `min-h-6` rather than bare `btn-xs`: daisyUI's xs button is 21px tall and
            WCAG 2.2 AA wants a 24x24 target. `btn-sm` clears that at 35px but costs
            48px of width, which is what pushes the wordmark over at a 375px viewport.

            `text-white` rather than daisyUI's own error foreground: measured,
            `--color-error-content` on `--color-error` is 4.08:1 in both themes, under
            the 4.5 floor for small text. White is 4.60:1 and passes in both. --%>
      <:actions>
        <button
          :if={show_reset?(@metrics)}
          id="reset-city"
          type="button"
          class="btn btn-xs btn-error text-white min-h-6"
          phx-click="wipe"
          title="Clear every block and start a new city — this cannot be undone"
        >
          Reset
        </button>
      </:actions>

      <%!-- The chrome in Layouts.app already shows the wordmark, so rendering it
            again here just duplicated it. Kept as sr-only rather than deleted:
            the page still needs exactly one h1 for screen readers. --%>
      <h1 class="sr-only">Armchair Metropolist</h1>

      <.collapse_banner metrics={@metrics} width={@width} cell_size={@cell_size} />

      <%!-- No breakpoint here on purpose. `flex-wrap` plus `min-w-fit` on the aside
            lets the *content* decide: the sidebar sits beside the grid exactly while
            it fits and drops below when it does not. Measured by forcing `flexDirection`
            on the real inner div below and resizing the real viewport (not a clone —
            cheaper to validate and immune to a clone's own `fit-content`/`flex-wrap`
            quirks), confirmed at the boundary pixel, the switch happens at viewport
            2254 expanded and 1415 collapsed — with Metrics stacked. Those are the
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
              a fixpoint rather than a runaway.

              But a fixpoint at the aside's **widest child**, which is not the same thing
              as the matrix's natural width and today is not the matrix at all. Measured
              2026-08-06, expanded: the totals footnote below is 1198px against the
              matrix's own 927px, so `100%` resolves to the footnote and stretches the
              table ~271px past its content. Collapsed it is the re-entry line, at 359px
              against 173px of matrix. That distinction is the whole subject of the
              threshold comment on the `max-[Npx]` classes further down — read it before
              reasoning about this sidebar's width from the table. --%>
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
                beside the grid (`W_row` below is never the smaller of the two measured
                windows, for exactly this reason), putting the legend under the grid at
                every ordinary window size. Keeping the children stacked by default keeps
                the sidebar's intrinsic width down to its widest single child and the wrap
                threshold at `W_col` rather than at the never-smaller `W_row` — a real
                saving expanded, and none at all collapsed, where the two coincide.

                **One threshold per state**, because the sidebar's width is what decides
                where it wraps and collapsing changes that width. A single constant is
                right in one state and wrong in the other — with only the expanded value,
                collapsing a wrapped legend moved it back beside the grid while Metrics
                stayed stubbornly alongside it.

                **Each threshold is the midpoint of a window, not a measured edge.** There
                are up to two wrap points per state — two whenever the arrangement chosen
                here feeds back into the sidebar's own width, one when it does not, which
                is the collapsed case today: stacked, the sidebar fits beside the grid from
                viewport `W_col`; side by side it may be a whole Metrics column wider and
                need `W_row`. Any constant inside `[W_col, W_row]` is self-consistent —
                at or above it the children stack and the sidebar fits beside the grid,
                below it they sit in a row and the sidebar has already dropped underneath.

                Measured by binary search on the live page (forcing `flexDirection` on the
                real inner div and resizing the real viewport, rather than a clone — cheaper
                to validate and immune to the clone's own `fit-content` quirks), then
                confirmed at the boundary pixel: expanded `[2254, 2415]`, collapsed
                `[1415, 1415]`. So the expanded midpoint below absorbs ±80px of content
                drift, and **the collapsed one absorbs none at all** — see below.

                **Reload at every candidate width.** Wrapping makes the page taller, which
                adds a vertical scrollbar, which takes ~15px back off the width and keeps it
                wrapped; unwrapped the page is short, there is no scrollbar, and that keeps
                it unwrapped. Both are self-consistent across a band as wide as the
                scrollbar, so resizing *into* a width answers differently from loading *at*
                it — 2240px read "fits" when resized down from 2300 and "wrapped" on a fresh
                load. Every figure here is from a fresh load at 1200px tall.

                **What actually sets these numbers is prose, not the matrix.** Wrapping is
                decided on the aside's *max-content* width (`min-width: fit-content` can
                only raise a flex item's hypothetical size, never lower it), and measured
                here that is the widest unbroken line it contains: expanded, the totals
                footnote at 1198px against the nine-column matrix's 927px; collapsed, the
                re-entry sentence at 359px against 173px of matrix. Both edges of both
                windows moved between the last measurement and this one, and the resource
                vocabulary was not why — a sentence added to the footnote and a re-entry
                block added by an unrelated change were. Re-measure when *any* line in the
                aside grows, not only when the table does, and move the value to the new
                midpoint rather than to whichever edge you happened to measure.

                Collapsed, `W_col == W_row`: the re-entry sentence is wider than either
                inner arrangement (173px stacked, 349px in a row), so the arrangement no
                longer feeds back at all and the window has collapsed to a single legal
                pixel. Nothing is wrong with 1415 — it is exactly right — but it has no
                slack, so treat any edit to that block as invalidating it. Note also that
                the URL line below is measured against the dev host: `break-all` shrinks its
                *min*-content, not its max-content, and the same line at a production-length
                host measures 506px, which would displace the sentence as the binding width.

                Tailwind v4 compiles `max-[N]` to `@media (width < N)`, exclusive, so N is
                the first viewport that should *not* get the row layout. --%>
          <div class={[
            "flex flex-col gap-4",
            if(@legend_detail, do: "max-[2335px]:flex-row", else: "max-[1415px]:flex-row")
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

          <%!-- The whole address, not the bare code. The code alone told a player what
                their city was called without telling them what to do with it — the route
                that accepts it (`/c/:code`) appeared nowhere on the page, so the only way
                to use the thing on offer was to guess it.

                `break-all` and the two-line split are for the sidebar, not for looks:
                `<aside>` is `min-w-fit`, so any unbreakable token it contains becomes a
                floor under the sidebar's width, which is why the URL is allowed to break
                mid-token and why it is not sharing a line with the sentence above it.

                What `break-all` does *not* do is protect the wrap thresholds measured
                above. Those are decided on max-content, which is the no-wrap width, and
                `break-all` only lowers min-content. Re-measured 2026-08-06: this block's
                first line is 359px, wider than anything the collapsed legend contains, so
                it is what sets the collapsed threshold today; the URL is 332px at the dev
                host and 506px at a production-length one, at which point it takes over.
                An earlier version of this comment claimed the line "has never been what
                decides that width", comparing the aside's *min*-content (~1020px, set by
                the expanded matrix) against these figures. That was the wrong box. --%>
          <div :if={@show_reentry?} class="text-xs opacity-70 mt-2">
            <p>This city lives in this browser. To open it somewhere else, go to:</p>
            <p>
              <a href={~p"/c/#{@city_id}"} class="font-mono underline break-all">
                {url(~p"/c/#{@city_id}")}
              </a>
            </p>
          </div>
        </aside>
      </div>
    </Layouts.app>
    """
  end

  # Rendered above the grid, deliberately outside the `<aside>`: the sidebar's width sets
  # the wrap thresholds documented in `render/1`, and this block's prose is far wider than
  # anything already in there.
  #
  # Status only. It names the header's Reset button rather than rendering a second copy of
  # it — `show_reset?/1` is a strict superset of `stalled`, so the control is guaranteed to
  # be on screen whenever this is.
  attr :metrics, :map, required: true
  attr :width, :integer, required: true
  attr :cell_size, :integer, required: true

  defp collapse_banner(assigns) do
    ~H"""
    <%!-- The grid's own width expression, so the two cannot drift apart. `max-w-full`
          and `box-border` are both required: without the first this overflows a narrow
          viewport instead of clamping, and without the second the padding and border
          push it past the grid's right edge at every width. --%>
    <div
      :if={@metrics.stalled}
      id="collapse-banner"
      class={[
        "box-border max-w-full rounded-lg border border-l-4 px-4 py-3",
        if(SimulationMetrics.game_over?(@metrics),
          do: "border-error bg-error/10",
          else: "border-warning bg-warning/10"
        )
      ]}
      style={"width: #{@width * @cell_size}px"}
    >
      <%!-- The headline is a verdict and the sentence under it is the mechanism, in that
            order. The verdict is earned rather than asserted: ticks are ignored while
            stalled, so health, tick and money are all constant, and both commands cost
            more than the treasury holds. --%>
      <p :if={SimulationMetrics.game_over?(@metrics)} class="font-semibold">
        Game over — this city is dead.
      </p>
      <p :if={not SimulationMetrics.game_over?(@metrics)} class="font-semibold">
        City stalled — nothing is changing on its own.
      </p>

      <p :if={SimulationMetrics.game_over?(@metrics)} class="text-xs opacity-80">
        Every block is dead and starving, so the clock has stopped. Building costs at least {trunc(
          Node.cheapest_construction_cost()
        )} and demolishing costs {trunc(Node.demolition_cost())}, and the treasury holds {trunc(
          @metrics.money
        )} — so
        nothing can restart it. <strong>Reset</strong>
        in the header clears the grid and starts a new city. This cannot be undone.
      </p>
      <p :if={not SimulationMetrics.game_over?(@metrics)} class="text-xs opacity-80">
        Every block is dead and starving, so the clock has stopped. The treasury still holds {trunc(
          @metrics.money
        )}: building always restarts it, and demolishing can too. Or <strong>Reset</strong>
        in the header to start over.
      </p>
    </div>
    """
  end

  # No living housing, and the reset would actually change something.
  #
  # The second disjunct is not redundant. Demolishing costs 10 and clears a node, so a
  # player can spend down to an empty grid holding 9: no nodes, so the city is not stalled
  # and there is no banner; nothing costs 10 or less; and an empty grid earns nothing,
  # forever. Without it that position has no affordance at all. With it, the button still
  # stays hidden on a fresh city, where a reset is a no-op — which is the only reason the
  # gate is not the bare `not housing_alive`.
  #
  # `bankrupt` rather than a second comparison against `Node.cheapest_action_cost/0`, so
  # the threshold has exactly one reader.
  defp show_reset?(metrics) do
    not metrics.housing_alive and (metrics.node_count > 0 or metrics.bankrupt)
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
              <th class="text-right">cost</th>
              <th :for={resource <- @resources} :if={@detail} class="text-right">{resource}</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={type <- @node_types}
              id={"legend-row-#{type}"}
              data-count={@metrics.by_type[type].count}
              data-affordable={to_string(affordable?(@metrics.money, type))}
              class={[
                type == @selected_type && "bg-primary/20",
                not affordable?(@metrics.money, type) && "opacity-40"
              ]}
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
                data-cell={"#{type}-cost"}
                class="text-right tabular-nums"
                title={cost_title(@metrics.money, type)}
              >
                {trunc(Node.construction_cost(type))}
              </td>
              <.resource_cell
                :for={resource <- @resources}
                :if={@detail}
                type={type}
                resource={resource}
                stats={@metrics.by_type[type]}
                amenity_marginal_labour={@metrics.amenity_marginal_labour}
                amenity_labour={@metrics.amenity_labour}
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
                    the cell no longer shows.

                    `colspan` counts the always-visible columns to its left — type,
                    `#` and `cost` — and no test can check it: `data-total={resource}`
                    stays correct on every cell no matter where the browser lays it
                    out, so the totals assertions all pass against a footer one cell
                    short, with money's total sitting under `labour` and the last
                    resource getting no column at all. Adding an always-visible column
                    means incrementing this by hand and looking at the table. --%>
              <th class="text-left" colspan="3">supplied/demanded · met this tick</th>
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
            line of prose sets this sidebar's width, so left visible it would hold the
            collapsed sidebar at this paragraph's own 1198px instead of the 359px the
            re-entry line below already imposes, and collapsing would reclaim almost
            nothing. Anything added here must stay short or wrappable.

            Re-measured 2026-08-06 (the earlier "437px instead of 127px" predates both
            the re-entry block and this paragraph's third sentence): expanded, these
            1198px are not merely a nuisance but the *binding* width of the whole
            sidebar — wider than the nine-column matrix's own 927px — so this paragraph,
            not the table, is what sets the expanded wrap threshold in `render/1`. Edit
            the wording here and that constant needs re-measuring. --%>
      <p :if={@detail} class="mt-1 text-xs opacity-60">
        Totals include the free baseline of 40 for power, water, waste and traffic, which
        belongs to no type. Labour and money have no free baseline.
        Labour's total also includes the park amenity; park's own row carries it.
      </p>
    </div>
    """
  end

  # Compared on the raw float, exactly as `ManageInfrastructure.place/4` does, so the
  # dimming and the refusal can never disagree about a type. The *displayed* treasury is
  # floored, and because every cost is a whole number `trunc(money) >= cost` exactly when
  # `money >= cost` — which is what keeps the greyed row and the printed balance
  # consistent.
  defp affordable?(money, type), do: money >= Node.construction_cost(type)

  # The row is dimmed, which is a visual-only signal; the title carries the same fact for
  # anyone who cannot see it. The select button stays enabled deliberately — choosing an
  # unaffordable type is harmless and is often what a player wants while waiting for
  # income.
  defp cost_title(money, type) do
    cost = trunc(Node.construction_cost(type))

    if affordable?(money, type),
      do: "costs #{cost}",
      else: "costs #{cost} — more than the treasury holds"
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
      <%!-- `trunc/1`, not `round/1`: this figure is spendable, and rounding it up makes
            the page contradict itself — a balance of 79.6 would read 80 while an 80-cost
            build is refused. Because every construction cost is a whole number,
            `trunc(money) >= cost` exactly when `money >= cost`, so the floored display
            and the domain's exact comparison agree. --%>
      <p id="metrics-treasury">Treasury: {trunc(@metrics.money)}</p>
      <p id="metrics-workforce">Workforce: ×{Float.round(@metrics.amenity, 2)}</p>
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
  attr :amenity_marginal_labour, :float, required: true
  attr :amenity_labour, :float, required: true

  defp resource_cell(assigns) do
    assigns =
      assigns
      |> assign(
        :marginal,
        marginal_cell(assigns.type, assigns.resource, assigns.amenity_marginal_labour)
      )
      |> assign(
        :total,
        total_cell(assigns.type, assigns.resource, assigns.stats, assigns.amenity_labour)
      )

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
  # because this is a property of the type.
  #
  # One exception, and it is signposted in the clause itself: `{:park, :labour}` depends
  # on the current city. The park amenity is a multiplier, so its *magnitude* is fixed at
  # `L × k` (= 5.0) by the arithmetic, but whether the city has already reached the ratio
  # cap is city state — and past the cap the honest figure changes sign.

  # `park`'s labour effect is a multiplier on supply, so it appears in neither table and
  # the general clause below would render an em dash — "does not interact with this
  # resource at all", which would be a lie about the one type that drives labour hardest.
  #
  # This still answers the question the function promises, "what one more block of this
  # type would do": the amenity another park would add, net of the labour it would draw.
  # Past parity that is negative, which is the honest figure — over-provisioning parks
  # costs labour rather than merely stopping helping.
  defp marginal_cell(:park, :labour, amenity_marginal_labour) do
    signed(amenity_marginal_labour - Map.get(Node.consumption(:park), :labour, 0.0))
  end

  defp marginal_cell(type, resource, _amenity_marginal_labour) do
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
  defp total_cell(_type, _resource, %{count: 0}, _amenity_labour), do: nil

  # The mirror of `marginal_cell/3`'s park clause, and needed for the same reason: park's
  # labour effect is in neither production table nor consumption table, so the general
  # clause below would take its `is_nil(produced)` branch and render the bare staffing draw
  # — `-3` for three parks whose amenity is worth +15. Bolder than the line above it, so
  # that was the wrong figure in the more prominent position.
  #
  # `amenity_labour` is what the placed parks actually contribute to supply, which is the
  # question a *total* asks; `marginal_cell/3` answers "one more" from a different figure.
  # It cannot be derived from this one — below the cap they coincide per park, at the cap
  # the marginal is 0.0 while the total is still large.
  #
  # `consumption` is already scaled by count in `build_by_type/1`, so this nets whole-row
  # against whole-row.
  defp total_cell(:park, :labour, stats, amenity_labour) do
    signed(amenity_labour - Map.get(stats.consumption, :labour, 0.0))
  end

  defp total_cell(_type, resource, stats, _amenity_labour) do
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

  # Both figures named, not just the refusal: the gap is what tells a player how long to
  # wait. `trunc/1` matches the treasury line's own flooring — a message saying the
  # treasury holds 80 while an 80-cost build was refused would be the same
  # self-contradiction in another place.
  #
  # The other three placement errors stay silent. `:out_of_bounds` is unreachable from a
  # grid that renders only in-bounds cells, and `:occupied` is nearly so, since the node
  # div sits above its cell and turns that click into a demolish. `:unknown_type` is
  # unreachable too: `type` always comes from `@selected_type`, which only ever changes
  # via the legend's own `select_type` buttons — one per member of `Node.types/0` — so
  # only a hand-crafted event bypassing the UI could produce a type this handler does not
  # recognize, and silence is the right response to that.
  defp unaffordable(type, money) do
    "Not enough money: #{type} costs #{trunc(Node.construction_cost(type))}, " <>
      "treasury holds #{trunc(money)}."
  end

  defp unaffordable_demolition(money) do
    "Not enough money: demolishing costs #{trunc(Node.demolition_cost())}, " <>
      "treasury holds #{trunc(money)}."
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
