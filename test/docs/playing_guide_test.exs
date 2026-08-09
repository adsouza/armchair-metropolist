defmodule ArmchairMetropolist.PlayingGuideTest do
  @moduledoc """
  Fails when `docs/PLAYING.md` disagrees with the simulation it describes.

  A strategy guide that quietly goes wrong is worse than none: a reader has no way to
  tell a stale number from a current one, and the whole value of the document is that
  its arithmetic can be trusted. So the reference tables are generated from `Node` and
  from measurements of `SimulationCalculator`, and this test is what makes the
  committed copy stay honest.

  Regenerate after changing a capacity, load or health rule:

      REGENERATE_PLAYING_GUIDE=1 mix test test/docs/playing_guide_test.exs
  """
  use ExUnit.Case, async: true

  alias ArmchairMetropolist.Domain.Entities.MunicipalBond
  alias ArmchairMetropolist.Domain.Entities.Node
  alias ArmchairMetropolist.Domain.Entities.SimulationMetrics
  alias ArmchairMetropolist.PlayingGuide

  @guide Path.expand("../../docs/PLAYING.md", __DIR__)

  test "every generated block in docs/PLAYING.md matches the domain" do
    original = File.read!(@guide)

    updated =
      Enum.reduce(PlayingGuide.blocks(), original, fn {name, body}, acc ->
        replace_block(acc, name, body)
      end)

    current? = normalise(updated) == normalise(original)

    if System.get_env("REGENERATE_PLAYING_GUIDE") in ~w(1 true) do
      if current? do
        IO.puts("\ndocs/PLAYING.md was already current.")
      else
        File.write!(@guide, updated)
        IO.puts("\ndocs/PLAYING.md regenerated. Review and commit the diff.")
      end
    else
      assert current?, """
      docs/PLAYING.md is out of date with the domain tables.

      A capacity, load or health rule has changed since the guide was
      written, so its numbers now describe a game that no longer exists.

      First difference:
        #{first_difference(updated, original)}

      Regenerate and review the diff:
          REGENERATE_PLAYING_GUIDE=1 mix test test/docs/playing_guide_test.exs
      """
    end
  end

  test "every documented support set is viable" do
    capacities = PlayingGuide.blocks()["capacities"]

    # Positive case first: a `refute` against "none" is trivially satisfied by an empty
    # block, so prove the block has real rows before refuting the bad one.
    assert capacities =~ "residential per tile"
    assert capacities =~ ~r/\| \*\*\d+\*\* \|/, "expected at least one measured row"

    refute capacities =~ "none",
           "a support set has no viable residential count — its labour demand probably " <>
             "outgrew what its water plants can house"
  end

  test "the guide states which resources are bads instead of reinterpreting them" do
    guide = File.read!(@guide)

    # Positive case first: the replacement framing must actually be present, so this
    # fails if the sentence is deleted outright rather than reworded.
    assert guide =~ "Waste, traffic, injuries and disease are bads"

    # And the instruction it replaced must be gone. Alone, this refute would pass
    # against a guide with the whole reference section deleted.
    refute guide =~ "as *capacity*",
           "the guide must not tell the reader to reinterpret a resource — that " <>
             "sentence is the bug this change removes"
  end

  test "the generated production block signs a bad and a good the same way the legend does" do
    # `net/3` in `SimulatorLive` and `signed_num/2` in this guide's own generator are two
    # independent implementations of the same sign convention, and nothing else pins them
    # to agreement — a "fix" to one followed by regenerating the guide from the other
    # would stay green. One pinned cell per polarity is enough to catch that: `industrial`
    # only produces waste (a bad, so producing reads negative) and `power_plant` only
    # produces power (a good, so producing reads positive).
    production = PlayingGuide.blocks()["production"]

    assert production =~ "waste -90"
    assert production =~ "power +120"
  end

  describe "the documented opening sequence" do
    # These pin the *advice*, not just its rendering. The guide tells a player to place
    # eight specific blocks in one specific order and promises nothing goes short on the
    # way; each test below is the arithmetic behind one clause of that promise, so a
    # balance patch that falsifies the advice fails the build instead of publishing a
    # sequence that kills the city.

    test "the sequence is a real second rung, not an empty list" do
      # First, because every `for` assertion below is vacuously true of no stages —
      # the same trap the capacities test guards against with its "none" refutation.
      stages = PlayingGuide.opening_stages()

      assert length(stages) == 8
      assert Enum.map(stages, & &1.type) |> Enum.uniq() |> length() > 3
    end

    test "every stage is fully supplied on all seven physical resources" do
      # The promise the whole section rests on: a player who keeps up never sees decay.
      # The first house is supplied by a market purchase; the power plant placed next
      # takes the rest of the sequence onto local generation.
      # `tightness` is demand ÷ supply, unclamped, and the stage reports whichever of the
      # five is highest — so `<= 1.0` on that one resource says all five are covered.
      # Asserted on the ratio rather than on `satisfaction`, which clamps at 1.0 and so
      # reads the same whether a resource has 60% headroom or none.
      for stage <- PlayingGuide.opening_stages() do
        {resource, demanded, supplied, tightness} = stage.tightest

        assert tightness <= 1.0,
               "stage #{stage.step} (place #{stage.type}) is short of #{resource}: " <>
                 "#{demanded} demanded against #{supplied} supplied. The documented " <>
                 "opening would decay here, so the guide's advice is now false."
      end
    end

    test "no stage of the sequence shows the insolvency warning" do
      # `@reaction_ticks` in `SimulationMetrics` is a constant, and this is what stops it
      # drifting into the tutorial. Measured, the tightest stage has a 23-tick rescue
      # window, so the 12-tick warning threshold keeps the tutorial quiet.
      #
      # This test is necessary but *not sufficient*, and treating it as sufficient was a
      # real defect in the design of this feature. Every stage here is fully supplied, which
      # is precisely the condition under which a window extrapolated from the current drain
      # is correct — so this fixture shares the blind spot of the bug it looks like it would
      # catch. The fixture that does catch it lives in `simulation_calculator_test.exs`
      # ("survives a city whose income falls while the treasury drains"), where the earners
      # are starving and the drain grows.
      for %{step: step, type: type, metrics: metrics} <- PlayingGuide.opening_solvency() do
        refute SimulationMetrics.warning?(metrics),
               "stage #{step} (place #{type}) warns about insolvency: treasury " <>
                 "#{trunc(metrics.money)}, escape #{inspect(metrics.escape)}, rescue " <>
                 "window #{inspect(metrics.rescue_window)}. A player following the guide " <>
                 "would be told their city is about to lock — lower @reaction_ticks or " <>
                 "re-measure the sequence."
      end
    end

    test "the sequence really is insolvent part-way, so the test above is not vacuous" do
      # Without this, a change that made `insolvent` always false — or that broke the money
      # ceiling so nothing is ever insolvent — would leave the refutation above passing for
      # the wrong reason. The plant and then transit carry upkeep before the shop is
      # there to cover it. Commerce arrives at step 4 and makes every later stage solvent.
      insolvent =
        PlayingGuide.opening_solvency()
        |> Enum.filter(& &1.metrics.insolvent)
        |> Enum.map(& &1.step)

      assert insolvent == [2, 3],
             "the opening's insolvent stages moved to #{inspect(insolvent)}; the quiet-" <>
               "tutorial test above only means something while some stage is insolvent"
    end

    test "all three bond choices retain their promised opening role" do
      assert MunicipalBond.issues() == [250.0, 400.0, 550.0]
      assert PlayingGuide.lean_save_and_grow_healthy?()

      balanced_gap = PlayingGuide.opening_max_gap_ticks(400.0)
      generous_gap = PlayingGuide.opening_max_gap_ticks(550.0)

      assert is_integer(balanced_gap) and balanced_gap >= 2,
             "Balanced no longer supports a deliberate direct opening"

      assert is_integer(generous_gap) and generous_gap > balanced_gap,
             "Generous no longer buys more measured reaction time than Balanced"
    end

    test "every documented route stays out of warning and default" do
      for principal <- MunicipalBond.issues() do
        assert PlayingGuide.documented_route_safe?(principal),
               "the documented #{principal} route now warns or defaults before completion"
      end
    end

    test "the finished opening retires every issue and redemption removes exactly its payment" do
      for principal <- MunicipalBond.issues() do
        assert PlayingGuide.opening_retires_issue?(principal),
               "the finished opening cannot retire the #{principal} issue"

        {cash_flow_gain, quoted_payment} = PlayingGuide.redemption_cash_flow_gain(principal)
        assert_in_delta cash_flow_gain, quoted_payment, 1.0e-9
      end
    end

    test "the city the sequence builds pays for itself" do
      # Physical satisfaction is covered above; money is not one of the five, and a
      # city that is fully supplied while its treasury drains is still doomed. Fails if
      # commercial's income is cut or the parks' upkeep is raised.
      assert PlayingGuide.opening_income() > 0.0,
             "the finished city nets #{PlayingGuide.opening_income()} per tick, so the " <>
               "treasury drains and the guide is recommending a slow death"
    end

    test "every single-block extension of the earner needs another local resource" do
      # Purchases may make an extension sustainable. This pins the narrower guide claim:
      # none is locally self-sufficient, so each adds a recurring market bill.
      rows = PlayingGuide.opening_wall_rows()

      assert length(rows) == length(Node.types())

      for %{type: type, tightest: {resource, demanded, supplied, tightness}} <- rows do
        assert tightness > 1.0,
               "adding #{type} to the earner leaves #{resource} at #{demanded}/#{supplied}, " <>
                 "which is locally supplied — update the guide's expansion advice"
      end
    end

    test "the pace note separates operating cash flow from debt service" do
      pace = PlayingGuide.blocks()["opening_pace"]

      assert pace =~ "+6 of operating cash flow"
      assert pace =~ "Debt service is separate"
      assert pace =~ "Lean can save at the core"
    end
  end

  test "the markers the generator writes into actually exist" do
    guide = File.read!(@guide)

    for name <- Map.keys(PlayingGuide.blocks()) do
      assert guide =~ "<!-- generated:#{name} -->",
             "docs/PLAYING.md is missing the opening marker for #{name}"

      assert guide =~ "<!-- /generated:#{name} -->",
             "docs/PLAYING.md is missing the closing marker for #{name}"
    end
  end

  # Deliberately `open.*?close` and not `open\n.*?\nclose`: the latter needs a newline
  # on each side of the body and so does not match an *empty* block, which is how a
  # freshly written document starts. The first version of this silently substituted
  # nothing and the test passed against empty tables — a check that could not fail.
  defp replace_block(text, name, body) do
    open = "<!-- generated:#{name} -->"
    close = "<!-- /generated:#{name} -->"
    pattern = ~r/#{Regex.escape(open)}.*?#{Regex.escape(close)}/s

    # A marker pair that did not match would leave the document untouched and look
    # exactly like agreement, so insist the substitution had somewhere to happen.
    assert Regex.match?(pattern, text),
           "the #{name} block was not found — check its markers in docs/PLAYING.md"

    Regex.replace(pattern, text, open <> "\n" <> body <> "\n" <> close)
  end

  # Compares what the tables *say*, not how they are laid out. A markdown formatter
  # pads cells to align the pipes and widens the `---` separator row to match, and a
  # guide that fails the build over cosmetic alignment is a guide whose test gets
  # deleted. A changed number still fails.
  defp normalise(text) do
    text
    |> String.split("\n")
    |> Enum.map_join("\n", fn line ->
      if String.contains?(line, "|") do
        line |> String.split("|") |> Enum.map_join("|", &normalise_cell/1)
      else
        String.trim_trailing(line)
      end
    end)
  end

  # A separator cell collapses to a single dash, so `---` and `-------` are the same
  # thing. Alignment colons go too: they are presentation, not content.
  defp normalise_cell(cell) do
    trimmed = String.trim(cell)
    if Regex.match?(~r/^:?-+:?$/, trimmed), do: "-", else: trimmed
  end

  # Without this a failure says only "out of date", which is true but useless.
  defp first_difference(expected, actual) do
    expected_lines = expected |> normalise() |> String.split("\n")
    actual_lines = actual |> normalise() |> String.split("\n")

    Enum.zip(expected_lines, actual_lines)
    |> Enum.find(fn {a, b} -> a != b end)
    |> case do
      nil ->
        "the documents differ in length, not content"

      {expected_line, actual_line} ->
        "expected: #{inspect(expected_line)}\n  in file: #{inspect(actual_line)}"
    end
  end
end
