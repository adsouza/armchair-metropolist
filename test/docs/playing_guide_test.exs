defmodule ArmchairMetropolist.PlayingGuideTest do
  @moduledoc """
  Fails when `docs/PLAYING.md` disagrees with the simulation it describes.

  A strategy guide that quietly goes wrong is worse than none: a reader has no way to
  tell a stale number from a current one, and the whole value of the document is that
  its arithmetic can be trusted. So the reference tables are generated from `Node` and
  from measurements of `SimulationCalculator`, and this test is what makes the
  committed copy stay honest.

  Regenerate after changing a production, consumption or health rule:

      REGENERATE_PLAYING_GUIDE=1 mix test test/docs/playing_guide_test.exs
  """
  use ExUnit.Case, async: true

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

      A production, consumption or health rule has changed since the guide was
      written, so its numbers now describe a game that no longer exists.

      First difference:
        #{first_difference(updated, original)}

      Regenerate and review the diff:
          REGENERATE_PLAYING_GUIDE=1 mix test test/docs/playing_guide_test.exs
      """
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
