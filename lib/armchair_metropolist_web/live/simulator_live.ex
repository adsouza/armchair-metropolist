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

  alias ArmchairMetropolist.Domain.Entities.{CityMap, MunicipalBond, Node, SimulationMetrics}
  alias ArmchairMetropolist.Infrastructure.Simulation.CityEngine

  @block_emojis %{
    power_plant: "⚡️",
    water_plant: "💧",
    industrial: "🏭",
    transit_hub: "🚉",
    residential: "🏘️",
    commercial: "🛍️",
    park: "🌳",
    hospital: "🏥"
  }

  # Injuries and disease are persistent city stocks rather than broadly exchanged
  # resources: only hospitals directly remove them. Giving each its own matrix column
  # leaves almost every row empty, so the legend keeps the six resources that support
  # useful read-down comparisons and summarizes hospital treatment in that row instead.
  @legend_resources [:power, :water, :waste, :traffic, :labour, :money]

  # Stable layout reservations, measured in the browser against the largest ordinary
  # values the bounded city can produce. A 32x32 city filled with one type has 1,024
  # blocks and six-digit row/footer totals; its expanded legend reaches 712.67px, so
  # 720 leaves 7px of rendering slack. The collapsed heading reaches 374.13px, so 384
  # leaves 10px. Metrics has independently reached 594.45px, hence its 600px ceiling.
  #
  # These are layout widths, not content clamps: the table wrapper still scrolls if a
  # grandfathered snapshot exceeds the bounded game's reasonable maximum. Reserving
  # them keeps changing counts, totals and purchase badges from moving whole sections.
  @expanded_legend_width 720
  @collapsed_legend_width 384
  @metrics_reserved_width 600

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
      |> assign(:bond_issues, [400.0, 250.0, 550.0])
      |> assign(:commands_enabled?, connected?(socket))
      |> assign(:legend_detail, true)
      |> assign(:confirming_reset?, false)
      |> assign(:health_tutorial, nil)
      |> assign(:health_tutorial_seen, initial_health_tutorial_seen(metrics))
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

  def handle_event("issue_bond", %{"principal" => principal}, socket) do
    result =
      with {amount, ""} <- Float.parse(principal) do
        CityEngine.issue_municipal_bond(socket.assigns.city_id, amount)
      else
        _invalid -> {:error, :invalid_issue}
      end

    case result do
      :ok -> {:noreply, socket}
      {:error, reason} -> {:noreply, put_flash(socket, :error, financing_error(reason))}
    end
  end

  def handle_event("issue_commercial_bond", _params, socket) do
    case CityEngine.issue_commercial_bond(socket.assigns.city_id) do
      :ok -> {:noreply, socket}
      {:error, reason} -> {:noreply, put_flash(socket, :error, financing_error(reason))}
    end
  end

  def handle_event("begin_sim", _params, socket) do
    case CityEngine.begin_simulation(socket.assigns.city_id) do
      :ok -> {:noreply, socket}
      {:error, reason} -> {:noreply, put_flash(socket, :error, financing_error(reason))}
    end
  end

  def handle_event("redeem_bond_25", _params, socket) do
    redeem_bond(socket, :minimum)
  end

  def handle_event("redeem_bond_full", _params, socket) do
    redeem_bond(socket, :full)
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

      {:error, :financing_required} ->
        {:noreply, put_flash(socket, :error, "Authorize a municipal bond issue before building.")}

      {:error, :bond_default} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Bond payment missed — clear the past-due balance before building."
         )}

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

  def handle_event("confirm_reset", _params, socket) do
    {:noreply, assign(socket, :confirming_reset?, true)}
  end

  def handle_event("cancel_reset", _params, socket) do
    {:noreply, assign(socket, :confirming_reset?, false)}
  end

  def handle_event("wipe", _params, socket) do
    :ok = CityEngine.reset(socket.assigns.city_id)

    # No stream clear here. `CityEngine.reset/1` is a synchronous call, so
    # `{:city_reset, city_map}` is already in this process's mailbox by the time it
    # returns, and `handle_info({:city_reset, ...})` below does strictly more: it also
    # resizes the grid. Clearing here too would render one frame at the pre-reset (grown)
    # grid size with an empty stream, before the resize catches up.
    {:noreply, assign(socket, :confirming_reset?, false)}
  end

  def handle_event("toggle_legend_detail", _params, socket) do
    {:noreply, assign(socket, :legend_detail, not socket.assigns.legend_detail)}
  end

  def handle_event("dismiss_health_tutorial", _params, socket) do
    {:noreply, assign(socket, :health_tutorial, nil)}
  end

  defp redeem_bond(socket, action) do
    case CityEngine.redeem_municipal_bond(socket.assigns.city_id, action) do
      :ok -> {:noreply, socket}
      {:error, reason} -> {:noreply, put_flash(socket, :error, financing_error(reason))}
    end
  end

  @impl true
  def handle_info({:city_delta, delta}, socket) do
    socket =
      Enum.reduce(delta, socket, fn {_id, node}, acc -> stream_insert(acc, :nodes, node) end)

    {:noreply, socket}
  end

  def handle_info({:city_metrics, metrics}, socket) do
    {:noreply, assign_metrics(socket, metrics)}
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
     |> assign(:confirming_reset?, false)
     |> assign(:health_tutorial, nil)
     |> assign(:health_tutorial_seen, MapSet.new())
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
          phx-click="confirm_reset"
          title="Discard this city and return to bond authorization"
        >
          Reset
        </button>
      </:actions>

      <div
        :if={@confirming_reset?}
        id="reset-confirmation"
        role="dialog"
        aria-modal="true"
        aria-labelledby="reset-confirmation-title"
        class="fixed inset-0 z-50 grid place-items-center bg-base-content/40 p-4 backdrop-blur-sm"
      >
        <section class="w-full max-w-md rounded-3xl border border-base-300 bg-base-100 p-6 shadow-2xl sm:p-7">
          <div class="flex items-start gap-4">
            <div class="grid size-11 shrink-0 place-items-center rounded-2xl bg-error/10 text-error">
              <.icon name="hero-arrow-path" class="size-6" />
            </div>
            <div>
              <h2 id="reset-confirmation-title" class="text-xl font-semibold tracking-tight">
                Reset this city?
              </h2>
              <p class="mt-2 text-sm leading-relaxed opacity-70">
                This permanently discards the city and returns you to municipal bond authorization.
                It cannot be undone.
              </p>
            </div>
          </div>

          <div class="mt-6 flex flex-col-reverse gap-3 sm:flex-row sm:justify-end">
            <button
              id="cancel-reset"
              type="button"
              class="btn btn-ghost"
              phx-click="cancel_reset"
              autofocus
            >
              Keep city
            </button>
            <button
              id="confirm-reset"
              type="button"
              class="btn btn-error text-white"
              phx-click="wipe"
            >
              Discard and reset
            </button>
          </div>
        </section>
      </div>

      <%!-- The chrome in Layouts.app already shows the wordmark, so rendering it
            again here just duplicated it. Kept as sr-only rather than deleted:
            the page still needs exactly one h1 for screen readers. --%>
      <h1 class="sr-only">Armchair Metropolist</h1>

      <.bond_issuance
        :if={is_nil(@metrics.bond)}
        issues={@bond_issues}
        commands_enabled?={@commands_enabled?}
        city_id={@city_id}
        show_reentry?={@show_reentry?}
      />

      <div :if={not is_nil(@metrics.bond)} id="financed-simulator">
        <.collapse_banner metrics={@metrics} width={@width} cell_size={@cell_size} />

        <.planning_panel
          :if={planning?(@metrics)}
          metrics={@metrics}
          commands_enabled?={@commands_enabled?}
        />

        <.commercial_bond_offer
          :if={@metrics.commercial_bond_offer}
          offer={@metrics.commercial_bond_offer}
          commands_enabled?={@commands_enabled?}
        />

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
          <div id="city-column" class="shrink-0">
            <.opening_goal_banner
              metrics={@metrics}
              tutorial={@health_tutorial}
              width={@width}
              cell_size={@cell_size}
            />

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
                  title={demolition_title(node, @metrics)}
                >
                  {block_emoji(node.type)}
                </div>
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
              with `w-fit` below so it keeps its compact intrinsic width instead of
              stretching to whichever other sidebar child happens to be widest. --%>
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
                sidebar is beside the city column. The colocated hook changes `data-position`
                from the city-column width, the real flex gap and the reserved sidebar width.
                Unlike measuring the live matrix, changing counts and totals cannot move this
                boundary; unlike a viewport breakpoint, grid growth still can. --%>
            <div
              id="legend-and-metrics"
              data-position="side"
              data-reserved-width={sidebar_reserved_width(@legend_detail)}
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
                  this.cityColumn = this.layout.querySelector("#city-column")
                  this.sidebar = this.el.closest("aside")
                  this.content = this.sidebar.querySelector("#legend-and-metrics")
                  this.placement = this.content.dataset.position
                  this.frame = null

                  this.syncPosition = () => {
                    this.frame = null

                    // LiveView renders `side` as the safe first-paint default on every
                    // patch. Restore the last computed placement first so an ordinary
                    // metrics patch cannot flash a different layout for one frame.
                    if (this.content.dataset.position !== this.placement) {
                      this.content.dataset.position = this.placement
                    }

                    const layoutWidth = this.layout.getBoundingClientRect().width
                    const cityColumnWidth = this.cityColumn.getBoundingClientRect().width
                    const columnGap = parseFloat(getComputedStyle(this.layout).columnGap) || 0
                    const reservedWidth = Number(this.content.dataset.reservedWidth)
                    const position =
                      cityColumnWidth + columnGap + reservedWidth <= layoutWidth
                        ? "side"
                        : "below"

                    if (this.placement !== position) {
                      this.placement = position
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
                  this.resizeObserver.observe(this.cityColumn)
                  this.resizeObserver.observe(this.sidebar)

                  // A LiveView patch may restore the server-rendered `side` default without
                  // changing any box size. Watching the attribute reapplies the stable state;
                  // the width attribute also changes intentionally when detail is toggled.
                  this.mutationObserver = new MutationObserver(this.scheduleSync)
                  this.mutationObserver.observe(this.content, {
                    attributes: true,
                    attributeFilter: ["data-position", "data-reserved-width"]
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
          </aside>
        </div>

        <%!-- Supporting detail belongs after the entire interactive layout, not inside the
              responsive legend/metrics row. `max-w-3xl` is 768px, the same ceiling as the
              growing city grid, so neither this copy nor the re-entry URL can widen the page.
              The address leads because it applies to the whole city; the resource explanation
              remains conditional with the detailed totals it explains. --%>
        <section
          id="legend-footnote"
          class="mt-4 max-w-3xl space-y-3"
        >
          <%!-- The whole address, not the bare code. The code alone would name the city
                without telling a player how to open it. Keeping the URL breakable prevents a
                production-length host from overflowing the grid-width footnote. --%>
          <div :if={@show_reentry?} id="city-reentry" class="text-xs opacity-70">
            <p>This city lives in this browser. To open it somewhere else, go to:</p>
            <p>
              <a href={~p"/c/#{@city_id}"} class="break-all font-mono underline">
                {url(~p"/c/#{@city_id}")}
              </a>
            </p>
          </div>

          <p :if={@legend_detail} class="text-xs leading-relaxed opacity-60">
            Totals include free capacity belonging to no type: 30 water supplied, 40 waste
            absorbed and 30 traffic absorbed. Power, labour and money have no free baseline.
            Injuries and disease are tracked as stocks in Metrics rather than as sparse columns;
            the hospital row shows its treatment rate. Traffic's healthy threshold falls from 100%
            of capacity at zero utilization to 80% at full utilization; demand above it creates
            injuries. Disease outbreaks begin every 49 ticks with one residential block and arrive
            three ticks sooner per additional block, down to every 10 ticks. Labour's total includes
            park amenity and the health-burden penalty; park's own row carries its amenity. Shortfalls
            in power, water, waste disposal and labour are bought automatically for 1 money per unit
            while the treasury can pay; purchased units count toward supplied totals. Each imported
            labour unit adds one traffic demand, and traffic itself cannot be bought.
          </p>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :metrics, :map, required: true
  attr :commands_enabled?, :boolean, required: true

  defp planning_panel(assigns) do
    ~H"""
    <section
      id="opening-planning"
      class="mb-4 overflow-hidden rounded-2xl border border-primary/35 bg-primary/5 shadow-sm"
    >
      <div class="flex flex-col gap-5 p-5 sm:flex-row sm:items-center sm:justify-between sm:p-6">
        <div class="flex max-w-3xl items-start gap-4">
          <div class="grid size-11 shrink-0 place-items-center rounded-2xl bg-primary/10 text-primary">
            <.icon name="hero-building-office-2" class="size-6" />
          </div>
          <div>
            <p class="text-xs font-bold uppercase tracking-[0.2em] text-primary">
              Opening planning
            </p>
            <h2 class="mt-1 text-xl font-semibold tracking-tight">Design before the clock starts</h2>
            <p class="mt-2 text-sm leading-relaxed opacity-75">
              Place blocks in any order and click any placed block to undo it for a full refund.
              Ticks, upkeep, imports, health changes, and debt service remain paused until you begin.
            </p>
          </div>
        </div>

        <div class="shrink-0 sm:text-right">
          <button
            id="begin-sim"
            type="button"
            class="btn btn-primary min-h-11 w-full px-6 shadow-md transition hover:-translate-y-0.5 hover:shadow-lg sm:w-auto"
            phx-click="begin_sim"
            disabled={not @commands_enabled? or @metrics.node_count == 0}
            title={
              if @metrics.node_count == 0,
                do: "Place at least one block before beginning",
                else: "Start simulation ticks and the 20-tick debt grace period"
            }
          >
            <.icon name="hero-play" class="size-4" /> Begin sim
          </button>
          <p :if={@metrics.node_count == 0} class="mt-2 text-xs opacity-60">
            Place at least one block first.
          </p>
        </div>
      </div>
    </section>
    """
  end

  attr :issues, :list, required: true
  attr :commands_enabled?, :boolean, required: true
  attr :city_id, :string, required: true
  attr :show_reentry?, :boolean, required: true

  defp bond_issuance(assigns) do
    ~H"""
    <section
      id="bond-issuance"
      class="mx-auto max-w-5xl rounded-3xl border border-base-300 bg-base-100 p-6 shadow-xl sm:p-8"
    >
      <div class="max-w-3xl">
        <p class="text-xs font-bold uppercase tracking-[0.24em] text-primary">Municipal financing</p>
        <h2 class="mt-2 text-3xl font-semibold tracking-tight">Authorize your city’s bond issue</h2>
        <p class="mt-3 leading-relaxed opacity-75">
          Authorize a municipal bond issue to fund the city, then plan with a paused clock and
          full-refund undo. Begin sim starts a 20-tick debt-service grace period. Then serial
          principal and 0.5% interest are due each tick, with final maturity 100 servicing ticks
          later. Optional redemption opens after the first 20 servicing ticks.
        </p>
      </div>

      <div class="mt-7 grid gap-4 lg:grid-cols-3">
        <article
          :for={principal <- @issues}
          id={"bond-option-#{trunc(principal)}"}
          class={[
            "relative flex flex-col rounded-2xl border p-5 transition hover:-translate-y-0.5 hover:shadow-lg",
            principal == MunicipalBond.recommended_issue() &&
              "border-primary bg-primary/5 ring-1 ring-primary/30",
            principal != MunicipalBond.recommended_issue() && "border-base-300 bg-base-200/30"
          ]}
        >
          <span
            :if={principal == MunicipalBond.recommended_issue()}
            class="absolute right-4 top-4 rounded-full bg-primary px-2.5 py-1 text-xs font-bold text-primary-content"
          >
            Recommended
          </span>
          <h3 class="text-xl font-semibold">{issue_name(principal)}</h3>
          <p class="mt-1 text-3xl font-bold tabular-nums">{trunc(principal)}</p>
          <p class="text-xs uppercase tracking-wide opacity-60">proceeds now</p>
          <dl class="mt-5 space-y-2 text-sm">
            <div class="flex justify-between gap-3">
              <dt class="opacity-65">First debt service</dt>
              <dd class="font-semibold tabular-nums">{bond_money(first_payment(principal))}</dd>
            </div>
            <div class="flex justify-between gap-3">
              <dt class="opacity-65">On-time interest</dt>
              <dd class="font-semibold tabular-nums">{bond_money(total_interest(principal))}</dd>
            </div>
            <div class="flex justify-between gap-3">
              <dt class="opacity-65">Call protection</dt>
              <dd class="font-semibold">20 service ticks</dd>
            </div>
            <div class="flex justify-between gap-3">
              <dt class="opacity-65">Final maturity</dt>
              <dd class="font-semibold">100 service ticks</dd>
            </div>
          </dl>
          <p class="mt-4 grow text-sm leading-relaxed opacity-70">{issue_role(principal)}</p>
          <p class="mt-4 text-xs leading-relaxed text-warning-content">
            Missed debt service blocks new construction until past-due amounts are cleared.
          </p>
          <button
            id={"issue-bond-#{trunc(principal)}"}
            type="button"
            class={[
              "btn mt-5 w-full",
              principal == MunicipalBond.recommended_issue() && "btn-primary",
              principal != MunicipalBond.recommended_issue() && "btn-outline"
            ]}
            phx-click="issue_bond"
            phx-value-principal={principal}
            disabled={not @commands_enabled?}
            autofocus={principal == MunicipalBond.recommended_issue()}
          >
            Authorize {issue_name(principal)}
          </button>
        </article>
      </div>

      <p :if={@show_reentry?} id="unissued-city-link" class="mt-6 text-xs opacity-60">
        Open this unissued city elsewhere at
        <a href={~p"/c/#{@city_id}"} class="font-mono underline break-all">
          {url(~p"/c/#{@city_id}")}
        </a>
      </p>
    </section>
    """
  end

  attr :offer, :map, required: true
  attr :commands_enabled?, :boolean, required: true

  defp commercial_bond_offer(assigns) do
    ~H"""
    <section
      id="commercial-bond-offer"
      class="mb-4 max-w-3xl rounded-2xl border border-primary/40 bg-primary/5 p-5 shadow-sm"
    >
      <div class="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <p class="text-xs font-bold uppercase tracking-[0.2em] text-primary">
            Commercial bridge available
          </p>
          <h2 class="mt-1 text-xl font-semibold tracking-tight">
            Keep a healthy city from running out of options
          </h2>
          <p class="mt-2 max-w-2xl text-sm leading-relaxed opacity-75">
            Your treasury is shrinking and no longer covers a {trunc(@offer.construction_cost)} commercial block. Issue {trunc(
              @offer.principal
            )} to restore that construction
            budget plus {pluralize_ticks(@offer.runway_ticks)} of projected expenses. This is
            serviced debt with the same 20-tick holiday and 100-tick term as the opening bond.
          </p>
        </div>
        <button
          id="issue-commercial-bond"
          type="button"
          class="inline-flex min-h-11 shrink-0 items-center justify-center rounded-xl bg-primary px-5 py-2.5 font-semibold text-primary-content shadow-sm transition hover:-translate-y-0.5 hover:shadow-md disabled:cursor-not-allowed disabled:opacity-50"
          phx-click="issue_commercial_bond"
          disabled={not @commands_enabled?}
        >
          Issue {trunc(@offer.principal)} bridge bond
        </button>
      </div>
    </section>
    """
  end

  defp pluralize_ticks(1), do: "1 tick"
  defp pluralize_ticks(ticks), do: "#{ticks} ticks"

  # Rendered above the grid, deliberately outside the `<aside>`: the sidebar's width sets
  # the wrap thresholds documented in `render/1`, and this block's prose is far wider than
  # anything already in there.
  #
  # Status only. Terminal variants name the header's Reset button rather than rendering a
  # second copy of it. Opening goals use the separate component below so they can sit inside
  # the grid column without moving urgent status above or below the planning controls.
  #
  # **One variant at a time, chosen by an ordered list rather than by independent `:if`s.**
  # The status states are not disjoint: a stalled city is also insolvent whenever its upkeep
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
      data-variant={@variant}
      class={[
        "box-border max-w-full rounded-lg border border-l-4 px-4 py-3",
        if(@variant in [:dead, :locked, :financing_locked, :bond_default],
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
      <%!-- Width-constrained. This is the widest of the terminal headlines (417px at
            max-content, measured 2026-08-08 at 16px/600 in ui-sans-serif) and it is what
            sets `@max_cell 128`: the banner shares the grid's width, a 2x2 grid is 256px,
            and this line needs a 245px banner to wrap to two lines rather than three.
            There are 11px of slack. Lengthening this sentence spends them, and no test
            will tell you -- Elixir cannot measure text. Re-measure in the browser. --%>
      <p :if={@variant == :locked} class="font-semibold">
        City locked — nothing more can be built or demolished.
      </p>
      <p :if={@variant == :financing_locked} class="font-semibold">
        City locked — the bond can never amortize from this economy.
      </p>
      <p :if={@variant == :stalled} class="font-semibold">
        City stalled — nothing is changing on its own.
      </p>
      <p :if={@variant == :bond_default} class="font-semibold">
        Bond payment missed — new construction is paused.
      </p>
      <p :if={@variant == :financing_warning} class="font-semibold">
        Debt service is closing your last escape — {@metrics.financing_rescue_window} ticks to act.
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
        in the header clears the grid and returns to bond authorization. This cannot be undone.
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
        in the header clears the grid and returns to bond authorization. This cannot be undone.
      </p>
      <p :if={@variant == :financing_locked} class="text-xs opacity-80">
        Even applying the whole treasury to redemption leaves debt whose new interest meets or
        exceeds this city's best possible operating surplus. <strong>Reset</strong>
        in the header to authorize a new issue and rebuild.
      </p>
      <p :if={@variant == :stalled} class="text-xs opacity-80">
        Every block is dead and starving, so the clock has stopped. The treasury still holds {trunc(
          @metrics.money
        )} — enough to demolish, and demolishing sometimes restarts the clock; placing a
        block always would, once it is affordable. Or <strong>Reset</strong>
        in the header to start over.
      </p>
      <p :if={@variant == :bond_default} class="text-xs opacity-80">
        Past-due interest or principal remains. Debt service will keep applying available cash;
        demolition remains available, and optional redemption can help once the bond is callable.
      </p>
      <p :if={@variant == :financing_warning} class="text-xs opacity-80">
        The bond cannot amortize against the city's best operating surplus. {escape_text(
          @metrics.financing_escape
        )} Act before debt service spends the required treasury.
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

  # The precedence between banners, in one place because the states overlap.
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
      SimulationMetrics.game_over?(metrics) and metrics.financing_locked -> :financing_locked
      SimulationMetrics.game_over?(metrics) -> :locked
      metrics.stalled -> :stalled
      bond_defaulted?(metrics) -> :bond_default
      SimulationMetrics.financing_warning?(metrics) -> :financing_warning
      SimulationMetrics.warning?(metrics) -> :warning
      true -> nil
    end
  end

  attr :metrics, :map, required: true
  attr :tutorial, :map, default: nil
  attr :width, :integer, required: true
  attr :cell_size, :integer, required: true

  defp opening_goal_banner(assigns) do
    assigns =
      assigns
      |> assign(:goal, assigns.tutorial || opening_goal(assigns.metrics))
      |> assign(:variant, if(assigns.tutorial, do: "health_tutorial", else: "opening_goal"))

    ~H"""
    <div
      :if={@goal}
      id="opening-goal-banner"
      data-variant={@variant}
      class="mb-3 box-border max-w-full rounded-lg border border-l-4 border-primary bg-primary/5 px-4 py-3"
      style={"width: #{@width * @cell_size}px"}
    >
      <div id="opening-goal">
        <div class="flex items-start justify-between gap-3">
          <p class="text-xs font-bold uppercase tracking-[0.18em] text-primary">
            <%= if @tutorial do %>
              City health
            <% else %>
              Suggested goal {@goal.step} of 4
            <% end %>
          </p>
          <button
            :if={@tutorial}
            id="dismiss-health-tutorial"
            type="button"
            class="btn btn-ghost btn-xs -mr-2 -mt-1 shrink-0"
            phx-click="dismiss_health_tutorial"
          >
            Got it
          </button>
        </div>
        <p class="mt-0.5 font-semibold">{@goal.title}</p>
        <p class="mt-1 text-xs leading-relaxed opacity-80">{@goal.body}</p>
      </div>
    </div>
    """
  end

  # Advisory goals are limited to a new issue's opening grace period. Grandfathered cities,
  # later-game cities and a city with a bridge offer keep the old banner behaviour unchanged.
  # Each milestone is derived from outcomes rather than node types, so the player can solve it
  # with any layout the economy supports.
  defp opening_goal(%{bond: bond} = metrics) do
    if opening_guidance?(metrics, bond) do
      power = Map.fetch!(metrics.resources, :power)
      labour = Map.fetch!(metrics.resources, :labour)
      money = Map.fetch!(metrics.resources, :money)
      operating_margin = money.supplied - money.demanded - metrics.market_spend

      cond do
        metrics.node_count == 0 or power.supplied < power.demanded ->
          %{
            step: 1,
            title: "Cover power locally",
            body: power_goal_body(metrics.node_count, power.supplied, power.demanded)
          }

        money.supplied <= money.demanded ->
          %{
            step: 2,
            title: "Establish positive operating income",
            body:
              "The plan earns #{whole(money.supplied)} per tick against #{whole(money.demanded)} of upkeep. Add earning capacity; commercial blocks are the strongest early source."
          }

        labour.supplied < labour.demanded and
            (metrics.by_type.residential.count == 0 or
               residential_improves_operating_margin?(metrics)) ->
          imported_labour = labour.demanded - labour.supplied

          %{
            step: 3,
            title: "Establish a local workforce",
            body:
              "The plan still relies on #{whole(imported_labour)} imported workers per tick, adding the same amount of traffic. Add residential capacity; parks can amplify the workforce once housing exists."
          }

        tightest_unmet = tightest_unmet_essential(metrics.resources) ->
          {resource, stats} = tightest_unmet

          %{
            step: 3,
            title: "Make the plan self-funding",
            body:
              "#{humanize(resource)} is only #{max(0, round(stats.satisfaction * 100))}% supplied. Add support or reduce demand so the city can remain healthy after it begins."
          }

        operating_margin <= 0.0 ->
          %{
            step: 3,
            title: "Make the plan self-funding",
            body:
              "Income is #{whole(money.supplied)} per tick, with #{whole(money.demanded)} upkeep and #{whole(metrics.market_spend)} of projected purchases. Revise until that total leaves a surplus."
          }

        planning?(metrics) ->
          %{
            step: 4,
            title: "Review the plan, then begin",
            body:
              "The current layout covers its essentials and projects a #{signed_whole(operating_margin)} operating margin. You can keep revising it or click Begin sim when ready."
          }

        true ->
          %{
            step: 4,
            title: "Use the grace period to build a reserve",
            body: reserve_goal_body(metrics, bond, operating_margin)
          }
      end
    end
  end

  defp opening_goal(_metrics), do: nil

  # These are session-scoped teaching prompts rather than simulation state. Persisting
  # tutorial acknowledgement in CityMap would turn UI state into a snapshot-compatibility
  # concern. A stock already above zero at mount is treated as previously seen, so reloads
  # do not replay the lesson; resetting the city clears the session flags with the stocks.
  defp initial_health_tutorial_seen(metrics) do
    [:injuries, :disease]
    |> Enum.filter(&(health_stock(metrics, &1) > 0.0))
    |> MapSet.new()
  end

  defp assign_metrics(socket, metrics) do
    previous = socket.assigns.metrics
    seen = socket.assigns.health_tutorial_seen

    newly_positive =
      Enum.filter([:injuries, :disease], fn topic ->
        not MapSet.member?(seen, topic) and health_stock(previous, topic) <= 0.0 and
          health_stock(metrics, topic) > 0.0
      end)

    seen = Enum.reduce(newly_positive, seen, &MapSet.put(&2, &1))

    tutorial =
      cond do
        hospital_present?(metrics) ->
          nil

        newly_positive == [] ->
          socket.assigns.health_tutorial

        true ->
          merge_health_tutorial(socket.assigns.health_tutorial, newly_positive)
      end

    socket
    |> assign(:metrics, metrics)
    |> assign(:health_tutorial, tutorial)
    |> assign(:health_tutorial_seen, seen)
  end

  defp health_stock(metrics, :injuries), do: metrics.injury_stock
  defp health_stock(metrics, :disease), do: metrics.disease_stock

  defp hospital_present?(metrics) do
    case Map.get(metrics.by_type, :hospital) do
      %{count: count} -> count > 0
      _missing -> false
    end
  end

  defp merge_health_tutorial(nil, newly_positive), do: health_tutorial(newly_positive)

  defp merge_health_tutorial(tutorial, newly_positive) do
    topics = Enum.filter([:injuries, :disease], &(&1 in tutorial.topics or &1 in newly_positive))
    health_tutorial(topics)
  end

  defp health_tutorial([:injuries]) do
    %{
      topics: [:injuries],
      title: "Why injuries appeared",
      body:
        "Traffic crossed its healthy threshold, which falls from 100% toward 80% of capacity as the network fills. Every ten trips above that threshold add one injury. Add transit capacity or reduce traffic; a healthy hospital treats ten injuries per tick."
    }
  end

  defp health_tutorial([:disease]) do
    %{
      topics: [:disease],
      title: "Why disease appeared",
      body:
        "A scheduled outbreak added disease. Outbreaks become larger and more frequent as residential blocks increase. A healthy hospital treats ten disease cases per tick; untreated cases persist and suppress local labour."
    }
  end

  defp health_tutorial([:injuries, :disease]) do
    %{
      topics: [:injuries, :disease],
      title: "Why health problems appeared",
      body:
        "Traffic above its utilization-sensitive healthy threshold added injuries, while a scheduled residential outbreak added disease. Add transit capacity or reduce traffic to prevent injuries; healthy hospitals treat ten injuries and ten disease cases per tick."
    }
  end

  # Local labour is not automatically cheaper labour. A new house also adds power, water,
  # waste and traffic loads plus one unit of income. Recommend it only when those recurring
  # effects improve the projected operating margin; otherwise a small labour import is the
  # more economical plan and should not block readiness.
  defp residential_improves_operating_margin?(metrics) do
    money = Map.fetch!(metrics.resources, :money)
    current_margin = money.supplied - money.demanded - metrics.market_spend
    projected_margin = projected_residential_margin(metrics)

    projected_margin > current_margin
  end

  defp projected_residential_margin(metrics) do
    capacity = Node.capacity(:residential)
    load = Node.load(:residential)
    money = Map.fetch!(metrics.resources, :money)

    projected_market_spend =
      Enum.reduce([:power, :water, :waste, :labour], 0.0, fn resource, total ->
        stats = Map.fetch!(metrics.resources, resource)
        demanded = stats.demanded + Map.get(load, resource, 0.0)

        supplied =
          if resource == :labour,
            do: projected_residential_labour(metrics, stats.supplied),
            else: stats.supplied + Map.get(capacity, resource, 0.0)

        # Every opening-market resource currently costs one per unit. Keeping the sum here
        # beside the goal makes the comparison include unfunded shortages as well as the
        # purchases the current treasury can afford.
        total + max(0.0, demanded - supplied - stats.carried)
      end)

    projected_income = money.supplied + Map.get(capacity, :money, 0.0)
    projected_upkeep = money.demanded + Map.get(load, :money, 0.0)
    projected_income - projected_upkeep - projected_market_spend
  end

  defp projected_residential_labour(metrics, current_labour) do
    base_labour = Map.fetch!(Node.capacity(:residential), :labour)
    housing = metrics.by_type.residential.count + 1
    parks = metrics.by_type.park.count
    new_amenity = 1.0 + min(parks / housing, 1.0)
    unboosted_current = current_labour / metrics.amenity

    (unboosted_current + base_labour * metrics.health_labour_multiplier) * new_amenity
  end

  defp power_goal_body(0, _supplied, _demanded) do
    "Start with enough local generation to support the first blocks you plan to add."
  end

  defp power_goal_body(_node_count, supplied, demanded) do
    "Local generation supplies #{whole(supplied)} of #{whole(demanded)} demand. Add enough generation to stop relying on imported electricity."
  end

  defp reserve_goal_body(metrics, %{original_principal: 400.0} = bond, operating_margin) do
    if metrics.by_type.park.count >= 2 do
      "Keep both parks and save toward 450 before the next expansion. That funds health care, income and supporting utilities while preserving a 100 reserve. The city projects a #{signed_whole(operating_margin)} operating margin with #{bond.opening_period_remaining} debt-free ticks remaining."
    else
      generic_reserve_goal_body(bond, operating_margin)
    end
  end

  defp reserve_goal_body(_metrics, bond, operating_margin) do
    generic_reserve_goal_body(bond, operating_margin)
  end

  defp generic_reserve_goal_body(bond, operating_margin) do
    "The city projects a #{signed_whole(operating_margin)} operating margin with #{bond.opening_period_remaining} debt-free ticks remaining. Keep the surplus positive before payments begin."
  end

  defp opening_guidance?(metrics, bond) do
    match?(%{legacy: false, defaulted: false}, bond) and
      Map.get(bond, :opening_period_remaining, 0) > 0 and
      is_nil(metrics.commercial_bond_offer)
  end

  defp tightest_unmet_essential(resources) do
    [:power, :water, :waste, :traffic, :labour]
    |> Enum.map(&{&1, Map.fetch!(resources, &1)})
    |> Enum.filter(fn {_resource, stats} -> stats.satisfaction < 1.0 end)
    |> Enum.min_by(fn {_resource, stats} -> stats.satisfaction end, fn -> nil end)
  end

  defp humanize(resource), do: resource |> Atom.to_string() |> String.capitalize()
  defp whole(value), do: value |> Float.round() |> trunc()

  defp signed_whole(value) when value >= 0.0, do: "+#{whole(value)}"
  defp signed_whole(value), do: "#{whole(value)}"

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

  # Reset is available after the player changes the city, not only after a state classifier
  # proves that it is dead. Automatic purchases can pin a healthy city's cash flow at zero,
  # and making the escape hatch depend on enumerating every such economic fixpoint merely
  # creates the next unreachable reset. A confirmation prompt protects a viable city from a
  # stray click.
  #
  # An empty grid can still differ from a new city: it may retain an authorized or redeemed
  # issue, treasury cash, or a waste/health backlog. All are changes a reset repairs.
  # The equality checks keep the control hidden on the untouched opening state even as its
  # tick counter advances in the background.
  defp show_reset?(metrics) do
    metrics.bond != nil or metrics.node_count > 0 or metrics.money != 0.0 or
      metrics.waste_stock != 0.0 or metrics.injury_stock != 0.0 or metrics.disease_stock != 0.0
  end

  defp issue_name(250.0), do: "Lean"
  defp issue_name(400.0), do: "Balanced"
  defp issue_name(550.0), do: "Generous"

  defp issue_role(250.0),
    do: "Least debt; reaches the profitable core, then asks you to save before finishing."

  defp issue_role(400.0),
    do: "Enough for a deliberate direct route, with debt service matched to the opening core."

  defp issue_role(550.0),
    do: "The most reaction margin and flexibility, in exchange for the largest payment."

  defp first_payment(principal), do: MunicipalBond.issue_terms(principal).first_payment
  defp total_interest(principal), do: MunicipalBond.issue_terms(principal).total_interest

  defp bond_money(value) when value > 0.0 and value < 0.01, do: "<0.01"

  defp bond_money(value) do
    rounded = Float.round(value * 1.0, 2)

    displayed =
      rounded
      |> :erlang.float_to_binary(decimals: 2)
      |> String.trim_trailing("0")
      |> String.trim_trailing(".")

    if rounded == value, do: displayed, else: "≈" <> displayed
  end

  defp bond_redeemed?(bond) do
    bond.outstanding_principal == 0.0 and bond.interest_arrears == 0.0
  end

  defp bond_defaulted?(metrics) do
    Enum.any?([metrics.bond, metrics.commercial_bond], fn
      nil -> false
      bond -> Map.get(bond, :defaulted, false)
    end)
  end

  defp legend_reserved_width(true), do: @expanded_legend_width
  defp legend_reserved_width(false), do: @collapsed_legend_width

  defp sidebar_reserved_width(detail) do
    max(legend_reserved_width(detail), @metrics_reserved_width)
  end

  defp planning?(metrics) do
    case metrics.bond do
      %{legacy: false, original_principal: principal} = bond when principal > 0.0 ->
        not Map.get(bond, :started, true)

      _other ->
        false
    end
  end

  defp bond_service_status(bond) do
    cond do
      bond_redeemed?(bond) ->
        "Bond redeemed"

      not Map.get(bond, :started, true) ->
        "Debt service begins after Begin sim"

      bond.paused ->
        "Payments paused while the city is stalled"

      bond.opening_period_remaining > 0 ->
        "Debt service begins in #{bond.opening_period_remaining} ticks"

      true ->
        "Next debt service #{bond_money(bond.next_payment)}"
    end
  end

  defp redemption_enabled?(bond, money, :minimum) do
    bond.callable and bond.redemption_amount > 25.0 and money >= 25.0
  end

  defp redemption_enabled?(bond, money, :full) do
    bond.callable and bond.redemption_amount > 0.0 and money >= bond.redemption_amount
  end

  defp redemption_title(bond, _money, _action) when not bond.callable do
    "Callable in #{bond.call_protection_remaining} servicing ticks"
  end

  defp redemption_title(bond, _money, :minimum) when bond.redemption_amount <= 25.0,
    do: "Use Redeem all for the remaining balance"

  defp redemption_title(_bond, money, :minimum) when money < 25.0,
    do: "The treasury must hold 25"

  defp redemption_title(bond, money, :full) when money < bond.redemption_amount,
    do: "The treasury does not cover the full redemption amount"

  defp redemption_title(_bond, _money, :minimum), do: "Redeem 25 at par"
  defp redemption_title(_bond, _money, :full), do: "Redeem the exact server-calculated balance"

  defp financing_error(:invalid_issue), do: "Choose one of the three offered bond issues."
  defp financing_error(:not_pristine), do: "This city can no longer authorize an opening issue."
  defp financing_error(:already_financed), do: "This city has already authorized its bond issue."
  defp financing_error(:already_started), do: "This simulation has already begun."

  defp financing_error(:empty_city),
    do: "Place at least one block before beginning the simulation."

  defp financing_error(:bond_not_issued), do: "No municipal bond has been issued."
  defp financing_error(:legacy_bond), do: "Legacy cities have no redeemable bond."
  defp financing_error(:bond_redeemed), do: "This bond has already been redeemed."
  defp financing_error(:not_callable), do: "Optional redemption is still call-protected."
  defp financing_error(:use_full_redemption), do: "Use Redeem all for the remaining balance."
  defp financing_error(:insufficient_funds), do: "The treasury cannot cover that redemption."
  defp financing_error(:already_issued), do: "This city has already issued its bridge bond."

  defp financing_error(:not_eligible),
    do: "The commercial bridge is no longer available for this city."

  # The six columnar resources are fixed and identical on every row, including where a
  # type does not touch one. Aligned columns are the feature: the question a player has
  # is "water is short, who is drinking it?", answered by reading one column down all
  # eight block types. Injuries and disease do not earn columns because only one type
  # directly changes them; hospital treatment is a compact annotation in that type row.
  attr :metrics, :map, required: true
  attr :node_types, :list, required: true
  attr :selected_type, :atom, required: true
  attr :detail, :boolean, required: true

  defp legend(assigns) do
    assigns =
      assigns
      |> assign(:resources, @legend_resources)
      |> assign(:reserved_width, legend_reserved_width(assigns.detail))

    ~H"""
    <%!-- Reserve the measured reasonable maximum so changing figures cannot push Metrics
          sideways. `shrink-0` is load-bearing when the sidebar is below the city and this
          panel shares a row with Metrics. The table remains `w-fit` inside the reservation,
          and its overflow wrapper handles a grandfathered snapshot wider than the bound. --%>
    <div id="legend-panel" class="shrink-0" style={"width: #{@reserved_width}px;"}>
      <%!-- "Legend" and not "Types": the toggle offers to hide the legend, the row ids
            are `legend-*`, and docs/PLAYING.md sends the player looking for a legend.
            The table's own `type` column header is caption enough for the rows. --%>
      <h2 id="legend-heading" class="mb-2 font-semibold">
        Legend:
        <span id="legend-selection-hint" class="font-normal opacity-60">
          tap on the name of a block type to select it
        </span>
      </h2>

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
              data-affordable={to_string(construction_available?(@metrics, type))}
              class={[
                type == @selected_type && "bg-primary/20",
                not construction_available?(@metrics, type) && "opacity-40"
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
                <div
                  :if={@detail and type == :hospital}
                  id="hospital-treatment-summary"
                  class="ml-2 mt-0.5 flex items-center gap-1 whitespace-nowrap text-[0.65rem] font-medium text-emerald-700 dark:text-emerald-300"
                  title="At full health; treatment scales with hospital health"
                >
                  <.icon name="hero-plus-circle" class="size-3" />
                  <span>-10 injuries/disease</span>
                </div>
              </td>
              <td data-cell={"#{type}-count"} class="text-right tabular-nums">
                {@metrics.by_type[type].count}
              </td>
              <td
                data-cell={"#{type}-cost"}
                class="text-right tabular-nums"
                title={cost_title(@metrics, type)}
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
                class={[
                  "text-right tabular-nums leading-tight",
                  totals_status(@metrics.resources, resource) == :warning &&
                    "text-orange-700 dark:text-orange-300",
                  totals_status(@metrics.resources, resource) == :shortfall &&
                    "text-red-700 dark:text-red-300"
                ]}
                data-supply-status={totals_status(@metrics.resources, resource)}
              >
                <% {demanded_supplied, met_this_tick, purchased} =
                  totals_cell(@metrics.resources, resource) %>
                <div>{demanded_supplied}</div>
                <div :if={not is_nil(met_this_tick)}>{met_this_tick}</div>
                <div
                  :if={purchased > 0.0}
                  data-purchased-resource={resource}
                  class="mt-0.5 whitespace-nowrap text-[0.65rem] font-semibold text-amber-700 dark:text-amber-300"
                  title={"Automatically purchased #{Float.round(purchased, 1)} #{resource} this tick"}
                >
                  +{Float.round(purchased, 1)} bought
                </div>
              </th>
            </tr>
          </tfoot>
        </table>
      </div>
    </div>
    """
  end

  # Compared on the raw float, exactly as `ManageInfrastructure.place/4` does, so the
  # dimming and the refusal can never disagree about a type. The *displayed* treasury is
  # floored, and because every cost is a whole number `trunc(money) >= cost` exactly when
  # `money >= cost` — which is what keeps the greyed row and the printed balance
  # consistent.
  defp affordable?(money, type), do: money >= Node.construction_cost(type)

  defp construction_available?(metrics, type) do
    not bond_defaulted?(metrics) and affordable?(metrics.money, type)
  end

  # The row is dimmed, which is a visual-only signal; the title carries the same fact for
  # anyone who cannot see it. The select button stays enabled deliberately — choosing an
  # unaffordable type is harmless and is often what a player wants while waiting for
  # income.
  defp cost_title(metrics, type) do
    cost = trunc(Node.construction_cost(type))

    cond do
      bond_defaulted?(metrics) ->
        "bond payment missed — clear the past-due balance through debt service before building"

      affordable?(metrics.money, type) ->
        "costs #{cost}"

      true ->
        "costs #{cost} — more than the treasury holds"
    end
  end

  # Always on screen, in both legend states. Tick, nodes, average health and offline
  # count, plus the tightest resource — which otherwise appears only in the totals row,
  # and that row is exactly what collapsing hides. `docs/PLAYING.md` calls the lowest
  # satisfaction the only number that matters, so it is the figure that has to survive.
  attr :metrics, :map, required: true

  defp metrics(assigns) do
    assigns =
      assigns
      |> assign(:tightest, tightest_resource(assigns.metrics.resources))
      |> assign(:automatic_purchases, automatic_purchases(assigns.metrics.resources))

    ~H"""
    <div id="metrics-panel">
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
      <p
        id="metrics-treasury"
        data-depleting={to_string(@metrics.treasury_delta < 0.0)}
        class={[
          @metrics.treasury_delta < 0.0 && "font-semibold text-red-700 dark:text-red-300"
        ]}
      >
        Treasury: {trunc(@metrics.money)}
      </p>
      <.bond_panel
        :if={@metrics.bond && not @metrics.bond.legacy && not bond_redeemed?(@metrics.bond)}
        bond={@metrics.bond}
        money={@metrics.money}
      />
      <.commercial_bond_panel
        :if={@metrics.commercial_bond && not bond_redeemed?(@metrics.commercial_bond)}
        bond={@metrics.commercial_bond}
      />
      <p :if={@metrics.market_spend > 0.0} id="metrics-market" class="leading-relaxed">
        <span>
          {if planning?(@metrics), do: "Projected purchases", else: "Automatic purchases"}: {Float.round(
            @metrics.market_spend,
            1
          )}/tick
        </span>
        <span class="ml-1 inline-flex flex-wrap gap-1 align-middle">
          <span
            :for={{resource, purchased} <- @automatic_purchases}
            data-market-resource={resource}
            class="inline-flex rounded-full border border-amber-300/70 bg-amber-50 px-1.5 py-0.5 text-xs font-semibold text-amber-800 dark:border-amber-600/60 dark:bg-amber-950/40 dark:text-amber-200"
          >
            {resource} +{Float.round(purchased, 1)}
          </span>
        </span>
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
        :if={
          @metrics.rescue_window && is_nil(@metrics.commercial_bond_offer) &&
            not SimulationMetrics.game_over?(@metrics)
        }
        id="metrics-rescue"
      >
        Rescue window: {@metrics.rescue_window} ticks
      </p>
      <%!-- `trunc/1` for the same reason as the treasury above: this is a
            quantity the player reasons about against whole-number capacities,
            and rounding 78.6 up to 79 would overstate a backlog by a unit. --%>
      <p id="metrics-landfill">Landfill: {trunc(@metrics.waste_stock)}</p>
      <p id="metrics-injuries">Injuries: {Float.round(@metrics.injury_stock, 1)}</p>
      <p id="metrics-disease">Disease: {Float.round(@metrics.disease_stock, 1)}</p>
      <p id="metrics-workforce">
        Workforce: parks ×{Float.round(@metrics.amenity, 2)}, health ×{Float.round(
          @metrics.health_labour_multiplier,
          2
        )}
      </p>
      <p :if={@tightest} id="metrics-tightest">{tightest_text(@tightest)}</p>
    </div>
    """
  end

  attr :bond, :map, required: true
  attr :money, :float, required: true

  defp bond_panel(assigns) do
    assigns =
      assigns
      |> assign(:minimum_enabled, redemption_enabled?(assigns.bond, assigns.money, :minimum))
      |> assign(:full_enabled, redemption_enabled?(assigns.bond, assigns.money, :full))

    ~H"""
    <section
      id="bond-panel"
      class="my-3 w-fit rounded-xl border border-base-300 bg-base-200/40 p-3"
    >
      <div class="flex items-center justify-between gap-3">
        <h3 class="font-semibold">Municipal bond</h3>
        <span :if={@bond.defaulted} class="badge badge-error badge-sm">In default</span>
      </div>
      <dl class="mt-2 space-y-1 text-sm">
        <div class="flex justify-between gap-4">
          <dt class="opacity-65">Principal outstanding</dt>
          <dd id="bond-principal" class="font-semibold tabular-nums">
            {bond_money(@bond.outstanding_principal)}
          </dd>
        </div>
        <div :if={@bond.interest_arrears > 0.0} class="flex justify-between gap-4 text-error">
          <dt>Interest past due</dt>
          <dd id="bond-interest-arrears" class="font-semibold tabular-nums">
            {bond_money(@bond.interest_arrears)}
          </dd>
        </div>
        <div :if={@bond.principal_arrears > 0.0} class="flex justify-between gap-4 text-error">
          <dt>Principal past due</dt>
          <dd id="bond-principal-arrears" class="font-semibold tabular-nums">
            {bond_money(@bond.principal_arrears)}
          </dd>
        </div>
        <div class="flex justify-between gap-4">
          <dt>Redemption amount</dt>
          <dd id="bond-redemption" class="font-semibold tabular-nums">
            {bond_money(@bond.redemption_amount)}
          </dd>
        </div>
      </dl>

      <p id="bond-service-status" class="mt-2 text-sm font-medium">{bond_service_status(@bond)}</p>
      <p
        :if={@bond.opening_period_remaining == 0 and not bond_redeemed?(@bond)}
        class="text-xs opacity-65"
      >
        Matures in {@bond.maturity_remaining} ticks
      </p>
      <p :if={not @bond.callable and not bond_redeemed?(@bond)} class="text-xs opacity-65">
        Callable in {@bond.call_protection_remaining} servicing ticks
      </p>

      <div
        :if={not bond_redeemed?(@bond)}
        id="bond-redemption-actions"
        class="mt-3 grid w-fit grid-cols-2 gap-2"
      >
        <button
          id="redeem-bond-25"
          type="button"
          class="btn btn-xs btn-outline"
          phx-click="redeem_bond_25"
          disabled={not @minimum_enabled}
          title={redemption_title(@bond, @money, :minimum)}
        >
          Redeem 25
        </button>
        <button
          id="redeem-bond-full"
          type="button"
          class="btn btn-xs btn-primary"
          phx-click="redeem_bond_full"
          disabled={not @full_enabled}
          title={redemption_title(@bond, @money, :full)}
        >
          Redeem all
        </button>
      </div>
    </section>
    """
  end

  attr :bond, :map, required: true

  defp commercial_bond_panel(assigns) do
    ~H"""
    <section
      id="commercial-bond-panel"
      class="my-3 rounded-xl border border-primary/30 bg-primary/5 p-3"
    >
      <div class="flex items-center justify-between gap-3">
        <h3 class="font-semibold">Commercial bridge bond</h3>
        <span
          :if={@bond.defaulted}
          class="rounded-full bg-error px-2 py-0.5 text-xs font-bold text-white"
        >
          In default
        </span>
      </div>
      <dl class="mt-2 space-y-1 text-sm">
        <div class="flex justify-between gap-4">
          <dt class="opacity-65">Principal outstanding</dt>
          <dd id="commercial-bond-principal" class="font-semibold tabular-nums">
            {bond_money(@bond.outstanding_principal)}
          </dd>
        </div>
        <div :if={@bond.interest_arrears > 0.0} class="flex justify-between gap-4 text-error">
          <dt>Interest past due</dt>
          <dd id="commercial-bond-interest-arrears" class="font-semibold tabular-nums">
            {bond_money(@bond.interest_arrears)}
          </dd>
        </div>
        <div :if={@bond.principal_arrears > 0.0} class="flex justify-between gap-4 text-error">
          <dt>Principal past due</dt>
          <dd id="commercial-bond-principal-arrears" class="font-semibold tabular-nums">
            {bond_money(@bond.principal_arrears)}
          </dd>
        </div>
      </dl>
      <p id="commercial-bond-service-status" class="mt-2 text-sm font-medium">
        {bond_service_status(@bond)}
      </p>
    </section>
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
        {"—", nil, 0.0}

      stats ->
        # `flow_satisfaction`, not `satisfaction`: the two numbers shown are demanded
        # and flow supply (local plus purchased), so the percentage under them has to be
        # computed on that same basis or it stops being derivable from what's on
        # screen. For money, `satisfaction` also counts the treasury and would make
        # this cell contradict its own two halves (23/13 while reading 100%).
        {
          "#{round(stats.demanded)}/#{round(stats.supplied + Map.get(stats, :purchased, 0.0))}",
          "#{Float.round(stats.flow_satisfaction * 100, 1)}%",
          Map.get(stats, :purchased, 0.0)
        }
    end
  end

  # Ten percent is the warning band, measured against the same flow supply printed in
  # the cell: local capacity plus anything bought this tick. Exactly meeting demand is
  # therefore orange rather than red; the city is still meeting its needs, but has no
  # buffer. A resource with no demand has no threshold to approach and stays neutral.
  defp totals_status(resources, resource) do
    case Map.get(resources, resource) do
      nil ->
        :healthy

      %{demanded: demanded} when demanded <= 0.0 ->
        :healthy

      stats ->
        available = stats.supplied + Map.get(stats, :purchased, 0.0)

        cond do
          available < stats.demanded -> :shortfall
          available <= stats.demanded * 1.1 -> :warning
          true -> :healthy
        end
    end
  end

  defp automatic_purchases(resources) do
    for resource <- Node.resources(),
        stats = Map.get(resources, resource, %{}),
        purchased = Map.get(stats, :purchased, 0.0),
        purchased > 0.0,
        do: {resource, purchased}
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

  defp demolition_title(node, metrics) do
    action =
      if planning?(metrics),
        do: "click to undo for a full #{trunc(Node.construction_cost(node.type))} refund",
        else: "click to demolish"

    "#{node.type} · #{node.status} (#{round(node.health)}%) — #{action}"
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
