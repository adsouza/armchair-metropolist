defmodule ArmchairMetropolistWeb.SimulatorLiveCase do
  @moduledoc """
  LiveView tests for the city dashboard.

  `async: false`: these tests inject application-env stub adapters, same as
  `city_engine_test.exs`, which is process-global. The test environment does not
  start the engine itself (`start_simulation: false` in `config/test.exs`, so it
  does not collide with `start_supervised!`/the Ecto sandbox), so each test starts
  its own `CityEngine` pointed at the in-memory `StubSnapshotRepository`, addressed
  at `CityEngine.default_city_id/0` — a stable constant with no production reader,
  kept only so a test can pin one value in one place. `mount/3` itself reads the
  session, so this same value is written into `conn`'s session below; the view and
  the test agree on which city they are looking at because both were told to, not
  because `mount/3` derives it from this constant itself.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      use ArmchairMetropolistWeb.ConnCase, async: false

      import ExUnit.CaptureLog
      import Phoenix.LiveViewTest

      alias ArmchairMetropolist.Domain.Entities.{CityMap, MunicipalBond, Node, SimulationMetrics}
      alias ArmchairMetropolist.Infrastructure.Simulation.CityEngine
      alias ArmchairMetropolist.Infrastructure.Simulation.CityRegistry
      alias ArmchairMetropolist.StubSnapshotRepository
      alias ArmchairMetropolistWeb.SimulatorLive

      # The topic for the city id this test's session (below) pins the view to —
      # broadcasting on the old hardcoded "city_simulation" would silently miss the view.
      @topic CityEngine.topic(CityEngine.default_city_id())
      @block_emojis [
        power_plant: "⚡️",
        water_plant: "💧",
        industrial: "🏭",
        transit_hub: "🚉",
        residential: "🏘️",
        commercial: "🛍️",
        park: "🌳"
      ]

      setup %{conn: conn} = context do
        previous_repo = Application.get_env(:armchair_metropolist, :snapshot_repository)

        on_exit(fn ->
          case previous_repo do
            nil -> Application.delete_env(:armchair_metropolist, :snapshot_repository)
            value -> Application.put_env(:armchair_metropolist, :snapshot_repository, value)
          end
        end)

        Application.put_env(:armchair_metropolist, :snapshot_repository, StubSnapshotRepository)

        start_supervised!(StubSnapshotRepository)
        StubSnapshotRepository.set_initial(initial_snapshot(context))
        start_supervised!({CityEngine, city_id: CityEngine.default_city_id()})

        # Every test but the two-visitor one (in `simulator_live_test.exs`) shares this
        # session's city id with
        # `start_supervised!`'s engine above, exactly as a single shared deployment did
        # before Task 4. Without this, EnsureCityId (router.ex) would hand each `conn` its
        # own random id, mount/3 would open an engine the DynamicSupervisor owns instead of
        # this test's `start_supervised!`, and it would outlive the test that opened it.
        conn = Plug.Test.init_test_session(conn, %{"city_id" => CityEngine.default_city_id()})

        # The two-visitor test (`simulator_live_test.exs`) still mounts two more cities through the production
        # ensure_started/1 path rather than start_supervised!/1, so nothing but this stops
        # them. ExUnit tears down `start_supervised!`'s "default" engine above before
        # on_exit callbacks run, so anything this sweep finds is one of those two leaks —
        # left running, each would sit subscribed to the global "city_tick" topic for
        # engine_linger_ms (30s in prod, unset here) and could checkpoint into whatever
        # :snapshot_repository a later test configures. Same problem and same fix as
        # city_engine_test.exs's "freezing when the last viewer leaves" describe block.
        on_exit(fn ->
          CityRegistry.Registry
          |> Registry.select([{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
          |> Enum.each(fn {_city_id, pid} ->
            capture_log(fn -> DynamicSupervisor.terminate_child(CityRegistry.Supervisor, pid) end)
          end)
        end)

        {:ok, conn: conn}
      end

      # `@tag treasury: n` seeds the balance of the city this test's engine hydrates.
      # There is no other way to set it: the engine owns the money, the refusal is decided
      # against the engine's copy, and this file starts its engine in `setup` — before any
      # test body could seed anything. Untagged tests get `{:error, :not_found}` exactly as
      # before, so the engine builds a fresh, unissued `CityMap`.
      #
      # The city is seeded *empty*: only the balance is preloaded, so every node in every
      # test is still placed through the running engine.
      defp initial_snapshot(%{treasury: money}) do
        {:ok, {0, %{legacy_city(40, 30) | money: money}}}
      end

      # `@tag :roomy_city` seeds an explicit 40x30 grandfathered city, for tests
      # whose subject has nothing to do with grid size and which place more blocks than a 2x2
      # holds. 40x30 is above the growth cap, so the grid cannot grow underneath them either --
      # which matters, because a growing grid changes the legal coordinate set between clicks.
      defp initial_snapshot(%{roomy_city: true}), do: {:ok, {0, legacy_city(40, 30)}}

      # `@tag :stalled_city` seeds a city that is stalled *and* bankrupt: three dead
      # residential blocks have no free power and no treasury for imports, so they stay
      # at zero health.
      defp initial_snapshot(%{stalled_city: true}), do: {:ok, {0, stalled_city(0.0)}}

      # The same city with money in the bank — stalled, but a rescue is still affordable.
      defp initial_snapshot(%{stalled_solvent_city: true}),
        do: {:ok, {0, stalled_city(105.0, 7)}}

      # `@tag :stalled_tiny_city` seeds the stalled city on the starting 2x2 grid, so the
      # banner's width can be pinned at the smallest grid the game ever renders. Three dead
      # residential blocks have no free power or import budget, so they stay at zero health.
      #
      # Seeded through `put_node/2` rather than placed, deliberately: three nodes on a 2x2 is
      # over the growth threshold, so a city built by placing them would arrive as a 4x4 and
      # render at 512px, and this test would pin the wrong number while still passing.
      defp initial_snapshot(%{stalled_tiny_city: true}) do
        city =
          Enum.reduce([{0, 0}, {1, 0}, {0, 1}], legacy_city(), fn {x, y}, map ->
            CityMap.put_node(map, %Node{
              Node.new(x, y, :residential)
              | health: 0.0,
                status: :offline
            })
          end)

        {:ok, {0, %{city | money: 0.0}}}
      end

      # `@tag :locked_city` seeds a physically self-sufficient insolvency softlock: one
      # house, one power plant and one water plant remain healthy, but ceiling 1 is below
      # upkeep 5 and the empty treasury cannot buy an escape action.
      defp initial_snapshot(%{locked_city: true}), do: {:ok, {0, locked_city()}}

      # The same city inside the warning band: 30 in the bank, a rescue window of 2 ticks
      # against a reaction budget of 12. Not bankrupt, so the player can still demolish the park.
      defp initial_snapshot(%{warned_city: true}), do: {:ok, {0, house_and_park(30.0)}}

      # And the same city too far out to warn: 2,000 lasts past the 60-tick
      # projection horizon, so there is no window to show.
      defp initial_snapshot(%{early_insolvent_city: true}),
        do: {:ok, {0, house_and_park(2_000.0)}}

      # `@tag :crowded_six_by_six` seeds a 6x6 city holding 25 nodes -- one below the 26 that
      # opens it: `crowded?/1` is `nodes * 10 > 7 * width * height`, so 25 nodes gives
      # `250 > 252` (false) and 26 gives `260 > 252` (true). Seeded via `put_node/2` in a loop
      # rather than by placing, so growth cannot fire while this fixture is being built -- a
      # city built by placing 25 residentials would cross the 26-node threshold on the very
      # placement this test means to drive itself, through a real click, afterwards.
      #
      # Laid out by index across the 6x6 grid (rows y = 0..3 filled, plus (0, 4)), which
      # leaves (1, 4) free for the real click in `simulator_live_grid_test.exs`. `residential`
      # at 15 each is comfortably
      # affordable at the seeded balance, for both the 25 free nodes and the one placed live.
      defp initial_snapshot(%{crowded_six_by_six: true}) do
        city =
          Enum.reduce(0..24, legacy_city(6, 6), fn i, map ->
            CityMap.put_node(map, Node.new(rem(i, 6), div(i, 6), :residential))
          end)

        {:ok, {0, %{city | money: 1_000.0}}}
      end

      defp initial_snapshot(%{callable_bond: true}) do
        city = bond_city(:callable)
        {:ok, {CityMap.snapshot_order(city), city}}
      end

      defp initial_snapshot(%{defaulted_bond: true}) do
        city = bond_city(:defaulted)
        {:ok, {CityMap.snapshot_order(city), city}}
      end

      defp initial_snapshot(%{redeemed_bond: true}) do
        city = bond_city(:redeemed)
        {:ok, {CityMap.snapshot_order(city), city}}
      end

      defp initial_snapshot(%{unissued_city: true}), do: {:error, :not_found}

      defp initial_snapshot(_context), do: {:ok, {{0, 0}, legacy_city()}}

      defp legacy_city(width \\ 2, height \\ 2) do
        %{CityMap.new(width, height) | municipal_bond: MunicipalBond.legacy(), money: 500.0}
      end

      defp bond_city(:callable) do
        {:ok, bond} = MunicipalBond.new(400.0)
        bond = MunicipalBond.start(bond, 0)

        bond =
          Enum.reduce(20..39, bond, fn tick, current ->
            MunicipalBond.service(current, tick, 10_000.0).bond
          end)

        %{CityMap.new() | tick: 40, revision: 3, money: 500.0, municipal_bond: bond}
      end

      defp bond_city(:defaulted) do
        {:ok, bond} = MunicipalBond.new(400.0)
        bond = MunicipalBond.start(bond, 0)
        bond = MunicipalBond.service(bond, 20, 0.0).bond

        city =
          CityMap.new()
          |> CityMap.put_node(Node.new(0, 0, :residential))

        %{city | tick: 21, revision: 4, money: 100.0, municipal_bond: bond}
      end

      defp bond_city(:redeemed) do
        city = bond_city(:callable)
        {:ok, bond} = MunicipalBond.redeem(city.municipal_bond, city.tick, 10_000.0)
        %{city | revision: city.revision + 1, municipal_bond: bond}
      end

      # Kept below every `initial_snapshot/1` clause, rather than between the two `:stalled_*`
      # ones, so the compiler sees all of that function's clauses grouped together.
      #
      # This used to be advisory and is now enforced. `mix.exs` sets `elixirc_paths(:test)` to
      # "lib" and "test/support", and these clauses lived in a `_test.exs` file until the split
      # — outside what `--warnings-as-errors` compiles, so the "clauses ... should be grouped
      # together" warning printed on every `mix test` and gated nothing. Here in `test/support`
      # it is compiled, so ungrouping these clauses now fails `mix precommit` outright.
      defp house_and_park(money) do
        city =
          legacy_city(40, 30)
          |> CityMap.put_node(Node.new(0, 0, :residential))
          |> CityMap.put_node(Node.new(1, 0, :park))

        %{city | money: money}
      end

      defp locked_city do
        legacy_city(40, 30)
        |> CityMap.put_node(Node.new(0, 0, :residential))
        |> CityMap.put_node(Node.new(1, 0, :power_plant))
        |> CityMap.put_node(Node.new(2, 0, :water_plant))
        |> Map.put(:money, 0.0)
      end

      defp stalled_city(money, count \\ 3) do
        city =
          Enum.reduce(0..(count - 1), legacy_city(40, 30), fn x, map ->
            CityMap.put_node(map, %Node{
              Node.new(x, 0, :residential)
              | health: 0.0,
                status: :offline
            })
          end)

        %{city | money: money}
      end

      # The markup for one streamed node, so a test can compare a single entry rather
      # than the whole page.
      defp rendered_node(html, dom_id) do
        [_, tail] = String.split(html, ~s{id="#{dom_id}"}, parts: 2)
        # 400, not 160: once a test needed to reach the node's `title` attribute — the
        # last one written, after id/class/style/phx-click/phx-value-x/phx-value-y — 160
        # chars cut off mid-`style`. 400 clears a full node tag with the longest type
        # name and status ("residential · degraded (100%) — click to demolish") with
        # room to spare.
        String.slice(tail, 0, 400)
      end

      defp broadcast(message) do
        Phoenix.PubSub.broadcast(ArmchairMetropolist.PubSub, @topic, message)
      end

      # How many background cells the grid rendered. A plain regex over the markup rather than
      # a DOM query — not because a parser is unavailable: `cost_text/2`, in
      # `simulator_live_legend_test.exs`, uses `LazyHTML`
      # for exactly this kind of parsing. Counting is what makes the regex the right choice
      # here regardless: this only needs the number of `phx-click="place"` attribute
      # occurrences, which needs no parse tree at all, whereas `LazyHTML.text/1` throws away
      # the very attribute this helper counts. Background cells are the only elements carrying
      # `phx-click="place"`; a placed node carries `phx-click="demolish"`.
      defp cell_count(html) do
        Regex.scan(~r/phx-click="place"/, html) |> length()
      end

      # Selects the type once, then places it at one cell — the two-step gesture the UI
      # actually requires, wrapped so a test can name the type and the coordinate together.
      defp place(view, type, x, y) do
        view
        |> element(~s{button[phx-click="select_type"][phx-value-type="#{type}"]})
        |> render_click()

        view
        |> element(~s{[phx-click="place"][phx-value-x="#{x}"][phx-value-y="#{y}"]})
        |> render_click()
      end
    end
  end
end
