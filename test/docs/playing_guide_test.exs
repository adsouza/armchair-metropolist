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

  alias ArmchairMetropolist.Domain.Entities.CityMap
  alias ArmchairMetropolist.Domain.Entities.Node
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
    assert guide =~ "Waste and traffic are bads"

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
    # seven specific blocks in one specific order and promises nothing goes short on the
    # way; each test below is the arithmetic behind one clause of that promise, so a
    # balance patch that falsifies the advice fails the build instead of publishing a
    # sequence that kills the city.

    test "the sequence is a real second rung, not an empty list" do
      # First, because every `for` assertion below is vacuously true of no stages —
      # the same trap the capacities test guards against with its "none" refutation.
      stages = PlayingGuide.opening_stages()

      assert length(stages) == 7
      assert Enum.map(stages, & &1.type) |> Enum.uniq() |> length() > 3
    end

    test "every stage is fully supplied on all five physical resources" do
      # The promise the whole section rests on: a player who keeps up never sees decay.
      # Fails if `water_plant`'s power draw rises above the 25 that fits under the free
      # baseline of 40 alongside one house and one park, or if `park`'s waste processing
      # capacity drops below the 8 the last two stages need.
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

    test "the opening grant covers the whole sequence" do
      # Nothing earns through the middle of this sequence, so the grant is the only
      # thing paying for it. Fails if the grant drops back towards 150, which cannot
      # reach the power plant.
      assert PlayingGuide.opening_cost() <= CityMap.opening_grant(),
             "the opening costs #{PlayingGuide.opening_cost()} but the grant is " <>
               "#{CityMap.opening_grant()} — a player following the guide would be " <>
               "refused part-way through it"
    end

    test "the city the sequence builds pays for itself" do
      # Physical satisfaction is covered above; money is not one of the five, and a
      # city that is fully supplied while its treasury drains is still doomed. Fails if
      # commercial's income is cut or the parks' upkeep is raised.
      assert PlayingGuide.opening_income() > 0.0,
             "the finished city nets #{PlayingGuide.opening_income()} per tick, so the " <>
               "treasury drains and the guide is recommending a slow death"
    end

    test "no single block extends the three-block earner" do
      # The premise of the whole section: if any one addition worked, the guide should be
      # recommending that instead of a seven-block run. Fails the moment a balance patch
      # opens a gentler route — for instance a higher power baseline — at which point the
      # advice needs rewriting rather than regenerating.
      rows = PlayingGuide.opening_wall_rows()

      assert length(rows) == length(Node.types())

      for %{type: type, tightest: {resource, demanded, supplied, tightness}} <- rows do
        assert tightness > 1.0,
               "adding #{type} to the earner leaves #{resource} at #{demanded}/#{supplied}, " <>
                 "which is sustainable — so the earner is no longer a dead end and the " <>
                 "opening sequence is no longer the only way forward"
      end
    end

    test "the savings ladder for slower play rises with the time taken" do
      rows = PlayingGuide.slow_opening_rows()

      assert length(rows) >= 3

      banks = Enum.map(rows, & &1.bank)

      assert banks == Enum.sort(banks) and length(Enum.uniq(banks)) == length(banks),
             "the ladder is #{inspect(banks)} — taking longer cannot need less money, " <>
               "so the search that produced this is wrong"
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
