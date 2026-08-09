defmodule ArmchairMetropolist.Infrastructure.Persistence.SnapshotVocabularyTest do
  use ExUnit.Case, async: true

  alias ArmchairMetropolist.Domain.Entities.{CityMap, MunicipalBond, Node}
  alias ArmchairMetropolist.Infrastructure.Persistence.SnapshotVocabulary

  # The standing rule of this file: NO RETIRED ATOM MAY APPEAR AS A LITERAL.
  # Writing one here would intern it at compile time, and every `:safe` decode
  # below would then succeed whether or not SnapshotVocabulary keeps it interned
  # — silently disarming the exact guard these tests exist to prove. Retired
  # atoms enter this file only inside the committed binary fixtures, which is
  # what makes those fixtures the one copy of the old vocabulary CI can see.
  # (docs/deploying.md used to say no such copy could exist; these are it.)

  @pre_rename_fixture "test/support/fixtures/city_snapshot_pre_transit_hub_rename.bin"
  @coverage_fixture "test/support/fixtures/city_snapshot_vocabulary_coverage.bin"

  test "a city stored before the transit-hub rename hydrates into the current vocabulary" do
    # The fixture is the payload behind the 2026-08-05 production 500: a real
    # tick-283 city whose node at 19:12 was placed under the retired name for
    # what is now :transit_hub. The sequence mirrors both adapters: intern the
    # vocabulary, decode `:safe`, modernize.
    SnapshotVocabulary.ensure_loaded!()

    city =
      @pre_rename_fixture
      |> File.read!()
      |> :erlang.binary_to_term([:safe])
      |> SnapshotVocabulary.modernize()

    assert city.tick == 283
    assert city.nodes["19:12"].type == :transit_hub
    assert Enum.all?(Map.values(city.nodes), &(&1.type in Node.types()))
  end

  test "the coverage fixture pins every node type and status the code currently ships" do
    # The ratchet. This binary was written by the code as of its last
    # regeneration (see generate_coverage_fixture.exs beside it), so it is a
    # committed disagreeing copy of the vocabulary: retire any atom it contains
    # without a @node_type_renames entry and the `:safe` decode below raises —
    # in CI, before the rename can reach a stored row it cannot read.
    #
    # Both comparisons derive their expected sets from Node, never from atom
    # literals: a literal here would keep a retired atom interned and let the
    # decode pass. That is also why the fixture is compared *after* modernize:
    # a correct rename entry keeps this green with no regeneration, while the
    # equality (not subset) check fails when the vocabulary gains an atom the
    # fixture has never seen — the signal to regenerate it.
    SnapshotVocabulary.ensure_loaded!()

    city =
      @coverage_fixture
      |> File.read!()
      |> :erlang.binary_to_term([:safe])
      |> SnapshotVocabulary.modernize()

    nodes = Map.values(city.nodes)

    assert nodes |> Enum.map(& &1.type) |> Enum.uniq() |> Enum.sort() ==
             Enum.sort(Node.types())

    assert nodes |> Enum.map(& &1.status) |> Enum.uniq() |> Enum.sort() ==
             Enum.sort(Node.statuses())

    assert city.revision == 7
    assert %MunicipalBond{} = city.municipal_bond
    assert city.municipal_bond.started_at_tick == 0
    assert city.municipal_bond.outstanding_principal == 400.0
    assert city.municipal_bond.interest_arrears == 2.25
    assert city.municipal_bond.principal_arrears == 4.0
    assert city.commercial_bond == nil
  end

  test "modernize/1 leaves a current-vocabulary city untouched" do
    city = %ArmchairMetropolist.Domain.Entities.CityMap{
      nodes: %{"0:0" => Node.new(0, 0, :transit_hub)}
    }

    assert SnapshotVocabulary.modernize(city) == city
  end

  test "modernize/1 supplies waste_stock for a payload written before the field existed" do
    SnapshotVocabulary.ensure_loaded!()

    decoded =
      @pre_rename_fixture
      |> File.read!()
      |> :erlang.binary_to_term([:safe])

    # Asserted first, and load-bearing: it proves the fixture really is a
    # missing-key payload. Without it this test would silently become a no-op the
    # day someone regenerates the fixture against the current struct.
    refute Map.has_key?(decoded, :waste_stock),
           "the fixture must predate waste_stock for this test to mean anything"

    assert SnapshotVocabulary.modernize(decoded).waste_stock == 0.0
  end

  test "modernize/1 supplies health stocks for a payload written before the fields existed" do
    SnapshotVocabulary.ensure_loaded!()

    decoded =
      @pre_rename_fixture
      |> File.read!()
      |> :erlang.binary_to_term([:safe])

    refute Map.has_key?(decoded, :injury_stock)
    refute Map.has_key?(decoded, :disease_stock)

    modernized = SnapshotVocabulary.modernize(decoded)
    assert modernized.injury_stock == 0.0
    assert modernized.disease_stock == 0.0
  end

  test "modernize/1 supplies no commercial bridge for an older payload" do
    SnapshotVocabulary.ensure_loaded!()

    decoded =
      @coverage_fixture
      |> File.read!()
      |> :erlang.binary_to_term([:safe])

    refute Map.has_key?(decoded, :commercial_bond)
    assert SnapshotVocabulary.modernize(decoded).commercial_bond == nil
  end

  test "modernize/1 does not reset a waste_stock the city already carries" do
    # The mutation this exists to catch is `Map.put` where `Map.put_new` belongs.
    # It passes the test above, and silently wipes a real backlog on every hydrate
    # — a save-corrupting bug that no other test in the suite can see.
    city = %{CityMap.new(40, 30) | waste_stock: 42.0}

    assert SnapshotVocabulary.modernize(city).waste_stock == 42.0
  end

  test "modernize/1 does not reset health stocks the city already carries" do
    city = %{CityMap.new(40, 30) | injury_stock: 9.0, disease_stock: 13.0}
    modernized = SnapshotVocabulary.modernize(city)

    assert modernized.injury_stock == 9.0
    assert modernized.disease_stock == 13.0
  end

  test "added_fields names every CityMap field an older release could not decode" do
    # `waste_stock` was added 2026-08-07. A field absent from this list is one a
    # rolled-back binary will fail to decode, so the list is pinned rather than
    # merely exercised.
    assert SnapshotVocabulary.added_fields() == [
             :waste_stock,
             :injury_stock,
             :disease_stock,
             :revision,
             :municipal_bond,
             :commercial_bond
           ]
  end
end
