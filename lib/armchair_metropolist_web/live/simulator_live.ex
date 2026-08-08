defmodule ArmchairMetropolistWeb.SimulatorLive do
  @moduledoc """
  The city dashboard: a growing grid, live infrastructure, and live metrics.

  ## Rendering strategy

  The background grid is a plain comprehension over `@grid_cells`, so it re-renders
  whenever the grid's dimensions change and is otherwise untouched — nothing in a tick
  changes `@grid_cells`. Placed infrastructure is tracked separately in
  `stream(:nodes, ...)`, keyed by the node's own `"x:y"` id via `dom_id: & &1.id`. Every
  tick only touches the handful of nodes that actually changed, so only those stream
  entries are patched. Nodes are absolutely positioned over the grid so the two layers
  stay independent.

  **A growth is the exception, and it re-streams every node.** A node's coordinates —
  and therefore its id — never change on growth; only the window around it does, gaining
  a ring on every side (see `CityMap.grow_if_crowded/1`). But cell size shrinks as the
  grid grows, and a LiveView stream does not re-render existing entries when an assign
  changes. `{:city_grew, ...}` therefore passes `reset: true`; see `handle_info/2`.

  ## Where the figures come from

  `CityEngine.snapshot/1` returns full resource statistics at mount, before any tick —
  it computes them through `UseCases.SummarizeCity`, since `Infrastructure` may not
  reach `Domain.Services`. The engine also broadcasts `{:city_metrics, …}` after every
  successful place and demolish, so the legend's counts move on the click rather than
  on the next tick.
  """
  use ArmchairMetropolistWeb, :live_view

  require Logger

  alias ArmchairMetropolist.Domain.Entities.CityMap
  alias ArmchairMetropolist.Domain.Entities.Node
  alias ArmchairMetropolist.Domain.Entities.SimulationMetrics
  alias ArmchairMetropolist.Infrastructure.Simulation.CityEngine

  @block_emojis %{
    power_plant: "⚡️",
    water_plant: "💧",
    industrial: "🏭",
    transit_hub: "🚉",
    residential: "🏘️",
    commercial: "🛍️",
    park: "🌳"
  }

  # Cell size is derived from the grid, not fixed, because the grid grows. The rendered
  # footprint runs 256px (2x2) -> 512px (4x4) -> 768px (6x6) and then holds between 748px
  # and 768px while cells shrink to @min_cell at the 32x32 cap.
  #
  # @max_cell 128 is *measured*, not chosen for looks. The collapse banner is styled to the
  # grid's own width, and its widest headline (":locked") needs a 245px banner to wrap to
  # two lines rather than three. 2 * 128 = 256 clears that with 11px of slack. 96 would
  # give 192px against a 193px three-line threshold — one pixel short, on a boundary that
  # is bistable. 128 also divides @target_px exactly, so every cell on the ramp is an
  # integer. Do not change these without re-measuring; see the design doc's "Why 128".
  #
  # @min_cell 24 is today's fixed value, which is what keeps a stored 40x30 city
  # pixel-identical: div(768, 40) is 19, clamped up to 24, giving the same 960x720.
  @min_cell 24
  @max_cell 128
  @target_px 768

  @doc false
  # Public only so the test suite can pin the clamps directly rather than inferring them
  # from rendered markup at five grid sizes.
  @spec cell_size(pos_integer(), pos_integer()) :: pos_integer()
  def cell_size(width, height) do
    min(@max_cell, max(@min_cell, div(@target_px, max(width, height))))
  end

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

    socket =
      socket
      |> assign_grid(city_map)
      |> assign(:metrics, metrics)
      |> assign(:node_types, Node.types())
      |> assign(:selected_type, List.first(Node.types()))
      |> assign(:legend_detail, true)
      # False only on the desktop target (see mount/3): a recovery code the desktop
      # cannot use — there is no "elsewhere" to return to it from, and it would
      # change on every launch — is worse than none.
      |> assign(:show_reentry?, Keyword.fetch!(opts, :show_reentry?))
      |> stream(:nodes, CityMap.nodes(city_map), dom_id: & &1.id)

    {:ok, socket}
  end

  # The six assigns that describe the grid, in one place, because they have to move
  # together: `:cell_size` is a function of the dimensions and `:grid_cells` is a function
  # of the whole window. Called from mount, from a growth, and from a reset — reassigning
  # `:width` without the others is the bug this exists to prevent.
  #
  # `:min_x`/`:min_y` carry the window's origin, which a growth moves into negative
  # coordinates while no node's `x`/`y` ever changes — see `CityMap.grow_if_crowded/1`.
  # The comprehension below walks world coordinates (`city_map.min_x` upward), not grid
  # indices starting at 0, so `@grid_cells` always names real cells even after growth.
  defp assign_grid(socket, %CityMap{} = city_map) do
    grid_cells =
      for y <- city_map.min_y..(city_map.min_y + city_map.height - 1),
          x <- city_map.min_x..(city_map.min_x + city_map.width - 1),
          do: {x, y}

    socket
    |> assign(:width, city_map.width)
    |> assign(:height, city_map.height)
    |> assign(:min_x, city_map.min_x)
    |> assign(:min_y, city_map.min_y)
    |> assign(:cell_size, cell_size(city_map.width, city_map.height))
    |> assign(:grid_cells, grid_cells)
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
      {:ok, _node} ->
        # No `stream_insert` here. The engine broadcasts `{:city_node_placed, node}` on
        # every successful placement and this view is subscribed to it, so inserting from
        # the reply as well did the same work twice. Demolish is the same shape below.
        {:noreply, socket}

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
      {:ok, _id} ->
        {:noreply, socket}

      {:error, :insufficient_funds} ->
        {:noreply,
         put_flash(socket, :error, unaffordable_demolition(socket.assigns.metrics.money))}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  def handle_event("wipe", _params, socket) do
    :ok = CityEngine.reset(socket.assigns.city_id)

    # No stream clear here. `CityEngine.reset/1` is a synchronous call, so
    # `{:city_reset, city_map}` is already in this process's mailbox by the time it
    # returns, and `handle_info({:city_reset, ...})` below does strictly more: it also
    # resizes the grid. Clearing here too would render one frame at the pre-reset (grown)
    # grid size with an empty stream, before the resize catches up.
    {:noreply, socket}
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

  # Carries the whole map, and re-streams every node rather than patching. Nothing is
  # re-keyed by a growth — a node's `x`/`y` and therefore its id never change, only the
  # window around it does — but cell size shrinks as the grid grows, and a LiveView
  # stream does not re-render existing entries when an assign changes. Without
  # `reset: true` the nodes keep the pixel geometry they were first rendered with: from
  # 6x6 -> 8x8 that is 128px boxes on a 96px grid, and after this change also the wrong
  # *position*, since the window's origin has moved and `@min_x`/`@min_y` changed too.
  #
  # Unconditional, not "only when cell size actually moved". That condition is true at
  # every growth from 6x6 upward, and getting it wrong is silent.
  def handle_info({:city_grew, city_map}, socket) do
    {:noreply,
     socket
     |> assign_grid(city_map)
     |> stream(:nodes, CityMap.nodes(city_map), reset: true)}
  end

  def handle_info({:city_reset, city_map}, socket) do
    # The grid resizes too: a reset returns the city to a 2x2 whatever it had grown to.
    # Streamed from `city_map.nodes` rather than the literal `[]`, matching the growth
    # clause above: both clauses are handed a whole map and trust it, rather than this one
    # relying on `ResetCity`/`CityMap.reset/1` happening to return an empty node set.
    {:noreply,
     socket
     |> assign_grid(city_map)
     |> stream(:nodes, CityMap.nodes(city_map), reset: true)}
  end

  # Anyone may broadcast on the subscribed topic, so unrecognised messages are dropped
  # rather than allowed to crash the view and lose the connection — mirrors
  # `CityEngine`'s own catch-all, for the same reason. Concretely reachable in a
  # mixed-version deploy: this branch changed `:city_reset` from a bare atom to
  # `{:city_reset, city_map}`, so an old-version engine broadcasting the bare atom to a
  # new-version view would otherwise hit no clause above and crash it.
  def handle_info(message, socket) do
    Logger.debug("SimulatorLive ignoring unexpected message: #{inspect(message)}")
    {:noreply, socket}
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
            it fits and drops below when it does not. That matters now that the grid grows:
            its rendered width ranges from 256px to 768px, with wider legacy snapshots,
            so a viewport breakpoint cannot reliably describe whether the sidebar wrapped.

            The old `min-[1450px]` committed to a side-by-side layout 181px before the
            matrix could fit in it, which is what produced the horizontal scrollbar
            inside the sidebar. Any replacement constant would drift when the grid,
            resources or type names changed; content-driven wrapping cannot. --%>
      <div id="simulator-layout" class="flex flex-wrap items-start gap-4">
        <div
          id="city-grid"
          class="relative shrink-0 border border-base-300"
          style={"width: #{@width * @cell_size}px; height: #{@height * @cell_size}px;"}
        >
          <%!-- `phx-value-x`/`phx-value-y` carry `x`/`y` themselves — the true, world
                coordinate the server places at — while `cell_style/3` is given
                `x - @min_x`/`y - @min_y`, a grid *index* counting from the window's
                visible corner. Conflating the two is what would re-key nodes: pixels
                need "how many cells from the left edge", the click needs "which cell
                this actually is", and after a growth those are no longer the same
                number. --%>
          <div
            :for={{x, y} <- @grid_cells}
            class="absolute border border-base-200 cursor-pointer"
            style={cell_style(x - @min_x, y - @min_y, @cell_size)}
            phx-click="place"
            phx-value-x={x}
            phx-value-y={y}
            title={"place #{@selected_type}"}
          >
          </div>

          <div id="nodes" phx-update="stream">
            <%!-- No coordinate in this title, and not only because the tooltip never
                  needed one to do its job — that job is disambiguating place-from-demolish,
                  which the verb already carries. With coordinates in the *background
                  cell's* title too, `assert render(view) =~ "2:3"` used to pass whether or
                  not a node was actually placed there — an accidental substring match on
                  the cell's own tooltip that shipped once and was only caught in review.
                  Dropping the coordinate from both titles makes that class of vacuous
                  assertion impossible rather than merely unlikely. --%>
            <div
              :for={{dom_id, node} <- @streams.nodes}
              id={dom_id}
              class={[
                "absolute flex cursor-pointer items-center justify-center",
                status_class(node.status)
              ]}
              style={node_style(node.x - @min_x, node.y - @min_y, @cell_size)}
              phx-click="demolish"
              phx-value-x={node.x}
              phx-value-y={node.y}
              title={"#{node.type} · #{node.status} (#{round(node.health)}%) — click to demolish"}
            >
              {block_emoji(node.type)}
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
        <%!-- No `grow`. It made the aside swallow its whole flex line when it wrapped
              below the grid, stretching the sidebar across otherwise useful space and
              pushing Metrics off the end.

              daisyUI also styles `.table` as `width: 100%`. The matrix overrides that
              with `w-fit` below: expanded, the totals footnote is wider than the matrix,
              and allowing the footnote to set every matrix column's width wastes the
              space the stacked totals row reclaimed. The aside remains sized by its
              widest child; only the table stops stretching to match that child. --%>
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

          <%!-- Column is the safe first paint: Metrics must stay below the legend while the
                sidebar is beside the grid. The colocated hook changes `data-position` only
                after measuring the real grid and sidebar tops; unlike a viewport breakpoint,
                that remains correct while the grid grows and for wider legacy snapshots. --%>
          <div
            id="legend-and-metrics"
            data-position="side"
            class="flex flex-col gap-4 data-[position=below]:flex-row"
          >
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

          <%!-- The hook owns only this ignored marker. It observes the surrounding layout
                and changes one data attribute on `#legend-and-metrics`; LiveView remains
                responsible for that container's children and can patch their metrics. --%>
          <div
            id="sidebar-placement-observer"
            phx-hook=".SidebarPlacement"
            phx-update="ignore"
          >
          </div>
          <script :type={Phoenix.LiveView.ColocatedHook} name=".SidebarPlacement">
            export default {
              mounted() {
                this.layout = this.el.closest("#simulator-layout")
                this.grid = this.layout.querySelector("#city-grid")
                this.sidebar = this.el.closest("aside")
                this.content = this.sidebar.querySelector("#legend-and-metrics")
                this.frame = null

                this.syncPosition = () => {
                  this.frame = null

                  const gridTop = this.grid.getBoundingClientRect().top
                  const sidebarTop = this.sidebar.getBoundingClientRect().top
                  const position = Math.abs(gridTop - sidebarTop) < 2 ? "side" : "below"

                  if (this.content.dataset.position !== position) {
                    this.content.dataset.position = position
                  }
                }

                this.scheduleSync = () => {
                  if (this.frame === null) {
                    this.frame = requestAnimationFrame(this.syncPosition)
                  }
                }

                this.resizeObserver = new ResizeObserver(this.scheduleSync)
                this.resizeObserver.observe(this.layout)
                this.resizeObserver.observe(this.grid)
                this.resizeObserver.observe(this.sidebar)

                // A LiveView patch may restore the server-rendered `side` default without
                // changing any box size. Watching the attribute makes the measured state
                // self-healing in that case too.
                this.mutationObserver = new MutationObserver(this.scheduleSync)
                this.mutationObserver.observe(this.content, {
                  attributes: true,
                  attributeFilter: ["data-position"]
                })

                this.scheduleSync()
              },

              destroyed() {
                this.resizeObserver.disconnect()
                this.mutationObserver.disconnect()

                if (this.frame !== null) {
                  cancelAnimationFrame(this.frame)
                }
              }
            }
          </script>

          <%!-- The whole address, not the bare code. The code alone told a player what
                their city was called without telling them what to do with it — the route
                that accepts it (`/c/:code`) appeared nowhere on the page, so the only way
                to use the thing on offer was to guess it.

                `break-all` and the two-line split are for the sidebar, not for looks:
                `<aside>` is `min-w-fit`, so any unbreakable token it contains becomes a
                floor under the sidebar's width, which is why the URL is allowed to break
                mid-token and why it is not sharing a line with the sentence above it.

                What `break-all` does *not* do is remove this block's influence on the
                sidebar's intrinsic width: it lowers min-content, not max-content.
                Measured 2026-08-06, the first line is 359px; the URL is 332px at the dev
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
  # Status only. It names the header's Reset button rather than rendering a second copy of it.
  # Whenever this banner reports a state the player cannot leave — `:dead` or `:locked`, both
  # of which are `game_over?/1` — `show_reset?/1` has that button on screen, because it now
  # carries `game_over?/1` as an explicit disjunct. It did not always: the guarantee used to
  # rest on `stalled` implying no living housing, and insolvency broke that implication. The
  # `:stalled` and `:warning` variants deliberately appear *without* a Reset button, since
  # both describe cities the player can still rescue.
  #
  # **One variant at a time, chosen by an ordered list rather than by independent `:if`s.**
  # The four states are not disjoint: a stalled city is also insolvent whenever its upkeep
  # outruns its ceiling, so `stalled` and `game_over?` and `warning?` can all be true of the
  # same city. Independent conditions rendered two headlines at once. `banner_variant/1`
  # below is the precedence, in one place.
  attr :metrics, :map, required: true
  attr :width, :integer, required: true
  attr :cell_size, :integer, required: true

  defp collapse_banner(assigns) do
    assigns = assign(assigns, :variant, banner_variant(assigns.metrics))

    ~H"""
    <%!-- The grid's own width expression, so the two cannot drift apart. `max-w-full`
          and `box-border` are both required: without the first this overflows a narrow
          viewport instead of clamping, and without the second the padding and border
          push it past the grid's right edge at every width. --%>
    <div
      :if={@variant}
      id="collapse-banner"
      class={[
        "box-border max-w-full rounded-lg border border-l-4 px-4 py-3",
        if(@variant in [:dead, :locked],
          do: "border-error bg-error/10",
          else: "border-warning bg-warning/10"
        )
      ]}
      style={"width: #{@width * @cell_size}px"}
    >
      <%!-- The headline is a verdict and the sentence under it is the mechanism, in that
            order. Each verdict is earned rather than asserted: for `:dead` and `:stalled`
            ticks are ignored while stalled, so health, tick and money are all constant; for
            `:locked` the treasury is provably pinned, since money demand is never
            health-scaled and the node set cannot change while nothing is affordable. --%>
      <p :if={@variant == :dead} class="font-semibold">
        Game over — this city is dead.
      </p>
      <%!-- Width-constrained. This is the widest of the four headlines (417px at
            max-content, measured 2026-08-08 at 16px/600 in ui-sans-serif) and it is what
            sets `@max_cell 128`: the banner shares the grid's width, a 2x2 grid is 256px,
            and this line needs a 245px banner to wrap to two lines rather than three.
            There are 11px of slack. Lengthening this sentence spends them, and no test
            will tell you -- Elixir cannot measure text. Re-measure in the browser. --%>
      <p :if={@variant == :locked} class="font-semibold">
        City locked — nothing more can be built or demolished.
      </p>
      <p :if={@variant == :stalled} class="font-semibold">
        City stalled — nothing is changing on its own.
      </p>
      <p :if={@variant == :warning} class="font-semibold">
        Upkeep outruns income — {@metrics.rescue_window} ticks to act.
      </p>

      <p :if={@variant == :dead} class="text-xs opacity-80">
        Every block is dead and starving, so the clock has stopped. Building costs at least {trunc(
          Node.cheapest_construction_cost()
        )} and demolishing costs {trunc(Node.demolition_cost())}, and the treasury holds {trunc(
          @metrics.money
        )} — so
        nothing can restart it. <strong>Reset</strong>
        in the header clears the grid and starts a new city. This cannot be undone.
      </p>
      <%!-- Deliberately not "dead". This city's blocks can be at full health — the point is
            that its bills outrun the most it could ever earn, so no amount of waiting helps.
            The ceiling is the honest figure to print beside the upkeep: it is what the city
            would earn with every earner at 100, which is why the comparison is permanent. --%>
      <p :if={@variant == :locked} class="text-xs opacity-80">
        Upkeep is {round(@metrics.resources.money.demanded)} a tick and this city could earn at
        most {round(@metrics.money_ceiling)} with every block at full health, so the treasury
        can never rise again. Building costs at least {trunc(Node.cheapest_construction_cost())} and
        demolishing costs {trunc(Node.demolition_cost())}, and the treasury holds {trunc(
          @metrics.money
        )}. <strong>Reset</strong>
        in the header clears the grid and starts a new city. This cannot be undone.
      </p>
      <p :if={@variant == :stalled} class="text-xs opacity-80">
        Every block is dead and starving, so the clock has stopped. The treasury still holds {trunc(
          @metrics.money
        )} — enough to demolish, and demolishing sometimes restarts the clock; placing a
        block always would, once it is affordable. Or <strong>Reset</strong>
        in the header to start over.
      </p>
      <p :if={@variant == :warning} class="text-xs opacity-80">
        Upkeep is {round(@metrics.resources.money.demanded)} a tick against a ceiling of {round(
          @metrics.money_ceiling
        )}, so the treasury is draining for good. {escape_text(@metrics.escape)} After that
        the city can never change again.
      </p>
    </div>
    """
  end

  # The precedence between the four banners, in one place because the states overlap.
  #
  # `:dead` before `:locked`: both are `game_over?/1`, and a city with every block on the
  # floor genuinely is dead, which is the more specific truth. `:stalled` before `:warning`:
  # a stalled city's treasury is frozen — `CityEngine` runs no tick — so a countdown would be
  # describing something that will not happen, while the stalled copy is accurate. That is
  # also enforced one layer down, in `SimulationMetrics.warning?/1`, which refuses a stalled
  # city outright; the ordering here does not depend on that and neither depends on the other.
  defp banner_variant(metrics) do
    cond do
      SimulationMetrics.game_over?(metrics) and metrics.stalled -> :dead
      SimulationMetrics.game_over?(metrics) -> :locked
      metrics.stalled -> :stalled
      SimulationMetrics.warning?(metrics) -> :warning
      true -> nil
    end
  end

  # Names the escape and prices it. The price is the load-bearing half: "demolish a park"
  # without the 10 does not tell the player whether they can still afford it, and affording
  # it is the entire subject of the warning.
  #
  # `:multiple` must not name a single action. It means no one block closes the gap, so
  # naming one would be an instruction that does not work — and the honest thing to say is
  # that this needs more than one, starting at the cheapest action's price.
  defp escape_text({:place, type, cost}) do
    "One #{type} block, at #{trunc(cost)}, would earn enough to cover it."
  end

  defp escape_text({:demolish, type, cost}) do
    "Demolishing one #{type}, at #{trunc(cost)}, would cut enough upkeep to cover it."
  end

  defp escape_text({:multiple, cost}) do
    "No single block closes the gap — it will take several, from #{trunc(cost)} each."
  end

  # Either the city has no living housing and the reset would change something, or the city
  # is over — which is not the same thing, and used not to be covered.
  #
  # The `node_count > 0` disjunct is not redundant. Demolishing costs 10 and clears a node, so
  # a player can spend down to an empty grid holding 9: no nodes, so the city is not stalled
  # and there is no banner; nothing costs 10 or less; and an empty grid earns nothing,
  # forever. Without it that position has no affordance at all. With it, the button still
  # stays hidden on a fresh city, where a reset is a no-op — which is the only reason the
  # first clause is not the bare `not housing_alive`.
  #
  # `bankrupt` rather than a second comparison against `Node.cheapest_action_cost/0`, so
  # the threshold has exactly one reader.
  #
  # `game_over?/1` is the disjunct this function was missing, and it is *not* implied by the
  # first clause. Until insolvency existed it was: `stalled` means every block is on the
  # floor, hence no living housing, so every game-over city already satisfied the left-hand
  # side. An insolvent city breaks that — measured, one house at 100 health beside one park
  # with an empty treasury can never change again by any route, and `housing_alive` is true
  # the whole time. Adding the disjunct here rather than widening the first clause keeps the
  # misclick mitigation the 2026-08-06 design relied on for every city that is still
  # playable.
  defp show_reset?(metrics) do
    (not metrics.housing_alive and (metrics.node_count > 0 or metrics.bankrupt)) or
      SimulationMetrics.game_over?(metrics)
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
        <table id="block-legend" class="table table-xs w-fit [&_th]:px-1 [&_td]:px-1">
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
                  class="btn btn-ghost btn-xs w-full justify-start gap-1.5"
                  phx-click="select_type"
                  phx-value-type={type}
                  aria-pressed={to_string(type == @selected_type)}
                >
                  <span aria-hidden="true">{block_emoji(type)}</span>
                  <span>{type}</span>
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
                    term the percentage went unlabelled anywhere on screen. Terse and
                    stacked because the label shares a narrow row with six numeric columns.
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
              <th class="text-left leading-tight" colspan="3">
                <div>demanded/supplied</div>
                <div>met this tick</div>
              </th>
              <th
                :for={resource <- @resources}
                data-total={resource}
                class="text-right tabular-nums leading-tight"
              >
                <% {demanded_supplied, met_this_tick} =
                  totals_cell(@metrics.resources, resource) %>
                <div>{demanded_supplied}</div>
                <div :if={not is_nil(met_this_tick)}>{met_this_tick}</div>
              </th>
            </tr>
          </tfoot>
        </table>
      </div>

      <%!-- Hidden with the totals row it explains — and not only for tidiness. Left
            visible, this paragraph would hold the collapsed sidebar at its own width
            instead of the re-entry line's width, and collapsing would reclaim little.

            `max-w-xl` is load-bearing. Its 576px cap sits just inside the compact matrix's
            measured 582px width instead of letting a 1054px max-content line stretch the
            sidebar well past the matrix. --%>
      <p :if={@detail} id="legend-footnote" class="mt-1 max-w-xl text-xs opacity-60">
        Totals include free capacity belonging to no type: 30 water supplied, 40 waste
        absorbed and 20 traffic absorbed. Power, labour and money have no free baseline.
        Labour's total also includes the park amenity; park's own row carries it. Shortfalls
        in power, water, waste disposal and labour are bought automatically for 1 money per
        unit while the treasury can pay; purchased units count toward supplied totals. Each
        imported labour unit adds one traffic demand, and traffic itself cannot be bought.
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
      <p :if={@metrics.market_spend > 0.0} id="metrics-market">
        Automatic purchases: {Float.round(@metrics.market_spend, 1)}/tick
      </p>
      <p :if={@metrics.imported_labour_traffic > 0.0} id="metrics-imported-labour-traffic">
        Imported-labour traffic: +{Float.round(@metrics.imported_labour_traffic, 1)}/tick
      </p>
      <%!-- Only while the drain is permanent, which is what `insolvent` means, and only while
            the projection actually found a deadline inside its horizon. A city merely spending
            faster than it earns today recovers as its earners heal, so a countdown there would
            be a prediction the city disproves — and a stalled city runs no ticks at all, which
            `SimulationMetrics.warning?/1` and `rescue_window`'s own nil both already reflect.

            "Rescue window" and not "Runway": this counts ticks until the *escape* stops being
            affordable, not ticks until the treasury empties. The two differ by
            `escape_price / drain`, which is 20 ticks for a 40-cost shop against a drain of 2 and
            only 4 against a drain of 9 — so "Runway" would be a wrong reading of a right number
            by an amount that is not even constant.

            The `game_over?/1` term is not redundant, and `0` is why: a bankrupt insolvent city
            has a window of exactly `0`, which is *truthy* in Elixir, so the bare value would
            render "Rescue window: 0 ticks" under a banner that has just said the city is over —
            sending the player to look for a rescue that no longer exists. --%>
      <p
        :if={@metrics.rescue_window && not SimulationMetrics.game_over?(@metrics)}
        id="metrics-rescue"
      >
        Rescue window: {@metrics.rescue_window} ticks
      </p>
      <%!-- `trunc/1` for the same reason as the treasury above: this is a
            quantity the player reasons about against whole-number capacities,
            and rounding 78.6 up to 79 would overstate a backlog by a unit. --%>
      <p id="metrics-landfill">Landfill: {trunc(@metrics.waste_stock)}</p>
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

    # Clamped at the display layer only. A backlog drives `satisfaction` below
    # zero — see `carried/2` — and "waste -280%" is noise where "waste 0%" beside
    # the Landfill line is legible. The domain keeps the signed value because
    # `CityEngine`'s `sort_by` needs it to rank waste against other shortfalls.
    percent = max(0, round(stats.satisfaction * 100))

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
    signed(amenity_marginal_labour - Map.get(Node.load(:park), :labour, 0.0))
  end

  defp marginal_cell(type, resource, _amenity_marginal_labour) do
    capacity = Map.get(Node.capacity(type), resource)
    load = Map.get(Node.load(type), resource)

    if is_nil(capacity) and is_nil(load) do
      "—"
    else
      signed(net(resource, capacity || 0.0, load || 0.0))
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
  # labour effect is in neither capacity table nor load table, so the general
  # clause below would take its `is_nil(capacity)` branch and render the bare staffing draw
  # — `-3` for three parks whose amenity is worth +15. Bolder than the line above it, so
  # that was the wrong figure in the more prominent position.
  #
  # `amenity_labour` is what the placed parks actually contribute to supply, which is the
  # question a *total* asks; `marginal_cell/3` answers "one more" from a different figure.
  # It cannot be derived from this one — below the cap they coincide per park, at the cap
  # the marginal is 0.0 while the total is still large.
  #
  # `load` is already scaled by count in `build_by_type/1`, so this nets whole-row
  # against whole-row.
  defp total_cell(:park, :labour, stats, amenity_labour) do
    signed(amenity_labour - Map.get(stats.load, :labour, 0.0))
  end

  defp total_cell(_type, resource, stats, _amenity_labour) do
    capacity = Map.get(stats.rated_capacity, resource)
    actual = Map.get(stats.actual_capacity, resource)
    load = Map.get(stats.load, resource)

    cond do
      is_nil(capacity) and is_nil(load) ->
        nil

      is_nil(capacity) ->
        signed(net(resource, 0.0, load))

      true ->
        rated_net = net(resource, capacity, load || 0.0)
        actual_net = net(resource, actual, load || 0.0)

        # Compared as displayed rather than as floats: capacity scales continuously
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
  #
  # Demand first, capacity second, for every resource regardless of polarity. This is
  # what lets one header sentence cover both: for power it reads "drawing 120 of 150
  # available", for waste "generating 80 against 60 of processing". It is also the
  # order `docs/PLAYING.md` already uses for its `tightest resource` column, so the
  # guide and the app no longer disagree about which figure comes first.
  defp totals_cell(resources, resource) do
    case Map.get(resources, resource) do
      nil ->
        {"—", nil}

      stats ->
        # `flow_satisfaction`, not `satisfaction`: the two numbers shown are demanded
        # and flow supply (local plus purchased), so the percentage under them has to be
        # computed on that same basis or it stops being derivable from what's on
        # screen. For money, `satisfaction` also counts the treasury and would make
        # this cell contradict its own two halves (23/13 while reading 100%).
        {
          "#{round(stats.demanded)}/#{round(stats.supplied + Map.get(stats, :purchased, 0.0))}",
          "#{Float.round(stats.flow_satisfaction * 100, 1)}%"
        }
    end
  end

  # The sign convention, in one place. For a negative resource a positive figure means
  # the type adds to the problem: `industrial` reads -90 because it removes 90 waste,
  # a house reads +10 because it emits 10.
  #
  # One function rather than a flip at each call site, deliberately. `marginal_cell/3`
  # and both branches of `total_cell/4` read the same two tables, and the
  # `is_nil(capacity)` branch is the one that fires for most types on a negative
  # resource — no type both produces and consumes waste, and none does for traffic. So
  # a partial patch leaves every emitter rendering backwards while the two removers
  # look right, which is the shape of defect this legend has shipped before.
  #
  # Not a complete inventory of every site that touches sign, though: the two
  # `{:park, :labour}` clauses (`marginal_cell/3` above and `total_cell/4` below) bypass
  # this function entirely, because labour is a positive resource and their special
  # casing is about the amenity multiplier, not polarity. That bypass is deliberate —
  # flagged here so a future negative resource with its own special-cased clause has to
  # decide whether it can bypass `net/3` too, rather than assuming the park precedent
  # means it can.
  defp net(resource, capacity, load) do
    if Node.negative_resource?(resource),
      do: load - capacity,
      else: capacity - load
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

  defp node_style(x, y, cell_size) do
    # Keep the block at 18px at the 24px cell-size floor, but let it fill the generous
    # cells of a young city: 96px in a 128px cell and 64px in a 96px cell. Below that
    # boundary, two-thirds scaling reaches the same 64px without a visual jump.
    font_size =
      if cell_size >= 96 do
        cell_size - 32
      else
        max(18, div(cell_size * 2, 3))
      end

    "#{cell_style(x, y, cell_size)} font-size: #{font_size}px; line-height: 1;"
  end

  defp status_class(:online), do: "bg-success/30 dark:bg-success/20"
  defp status_class(:degraded), do: "bg-warning/70"
  defp status_class(:offline), do: "bg-error/70"

  defp block_emoji(type), do: Map.fetch!(@block_emojis, type)
end
