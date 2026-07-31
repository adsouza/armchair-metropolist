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

  ## `metrics.resources` before the first tick

  Immediately after mount, `CityEngine.snapshot/0` reports `resources` as an
  empty map (see `CityEngine`'s moduledoc: `Infrastructure` cannot reach
  `Domain.Services`, so resource stats only ever arrive via tick metrics).
  The resource panel iterates `@metrics.resources` as a map rather than
  indexing fixed keys, and shows a "waiting for first tick" placeholder while
  it is empty — it self-corrects the moment `{:city_metrics, m}` lands.
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

      <div class="mb-4">
        <h2 class="font-semibold mb-2">Place</h2>
        <div class="flex flex-wrap gap-2">
          <button
            :for={type <- @node_types}
            type="button"
            phx-click="select_type"
            phx-value-type={type}
            class={["btn btn-sm", type == @selected_type && "btn-primary"]}
          >
            {type}
          </button>
        </div>
      </div>

      <div class="mb-4">
        <h2 class="font-semibold mb-2">Metrics</h2>
        <p>Tick: {@metrics.tick}</p>
        <p>Nodes: {@metrics.node_count}</p>
        <p>Avg health: {Float.round(@metrics.avg_health, 1)}</p>
        <p>Offline: {@metrics.offline_count}</p>

        <p :if={map_size(@metrics.resources) == 0} class="italic opacity-70">
          Waiting for first tick…
        </p>
        <ul :if={map_size(@metrics.resources) > 0}>
          <li :for={{resource, stats} <- @metrics.resources}>
            {resource}: {Float.round(stats.satisfaction * 100, 1)}%
          </li>
        </ul>
      </div>

      <div
        class="relative border border-base-300"
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
    </Layouts.app>
    """
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
