# Regenerates city_snapshot_vocabulary_coverage.bin — the committed payload that
# pins the *current* persistence vocabulary. Its companion test in
# snapshot_vocabulary_test.exs is what turns a future atom retirement red in CI.
#
# Run it from the repository root whenever the vocabulary GAINS an atom (a new
# node type or status), so the new atom joins the pinned set:
#
#     mix run --no-start test/support/fixtures/generate_coverage_fixture.exs
#
# A *rename* needs no regeneration: the companion test compares the fixture
# after `SnapshotVocabulary.modernize/1`, so a correct `@node_type_renames`
# entry keeps it green while the old binary keeps guarding the retired atom.
alias ArmchairMetropolist.Domain.Entities.{CityMap, Node}

# One node per type, healths cycling so all three statuses appear.
healths = [100.0, 40.0, 5.0]

city =
  Node.types()
  |> Enum.with_index()
  |> Enum.reduce(CityMap.new(12, 12), fn {type, i}, map ->
    health = Enum.at(healths, rem(i, length(healths)))
    node = %{Node.new(i, 0, type) | health: health, status: Node.status_for(health)}
    CityMap.put_node(map, node)
  end)

path = "test/support/fixtures/city_snapshot_vocabulary_coverage.bin"
File.write!(path, :erlang.term_to_binary(%{city | tick: 1}, [:compressed]))
IO.puts("wrote #{path}")
