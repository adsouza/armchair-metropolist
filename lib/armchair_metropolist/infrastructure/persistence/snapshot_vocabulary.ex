defmodule ArmchairMetropolist.Infrastructure.Persistence.SnapshotVocabulary do
  @moduledoc """
  The modules that define every atom a persisted city can contain.

  Both snapshot adapters decode with `:erlang.binary_to_term/2` and the `:safe`
  option, which refuses to *create* atoms. A stored city is made of them: struct
  names, every struct key, every node type, every status. The engine hydrates in
  `handle_continue/2` before anything else has touched the domain entities, so on a
  cold VM those modules are unloaded, their atoms do not exist, and the decode
  raises — silently discarding the city in the file adapter (rescued to
  `:malformed`, folded into `:not_found`) and crash-looping the engine in the
  Postgres one.

  Loading these modules first interns every atom a legitimate payload can carry.
  `:safe` then still does its real job: rejecting a payload carrying anything else.

  ## Adding to this list

  It exists so there is exactly one place to update, but it cannot notice when it
  has gone stale — so the entity modules carry a matching warning at their
  `defstruct`. Extend it whenever a persisted struct gains a field whose values are
  atoms drawn from a module not already listed, or when a new struct is reachable
  from `CityMap`. `test/.../file_snapshot_store_test.exs` covers the current set in
  a genuinely cold VM; keep that city maximal.

  ## Retiring an atom: `@node_type_renames`

  Renaming a node type retires its atom from every module above, so stored rows
  written under the old name stop decoding — `:safe` refuses to recreate the atom,
  the visitor's engine crash-loops on the server, and the desktop adapter silently
  discards the city while its stale envelope tick blocks every later save
  (docs/deploying.md, "The other trap: renaming a node type"). The 2026-08-05
  production outage was exactly this.

  `@node_type_renames` is the remedy: its keys are the retired atoms, kept interned
  by the literal below for as long as this module exists, and `modernize/1` rewrites
  them to their successors as a city hydrates. Both adapters call it on every decoded
  payload, so by the time a city leaves the persistence layer it speaks only the
  current vocabulary.

  Complete a rename by adding one entry here. Nothing else — no purge, no data
  migration, and no desktop remediation, which is the point: v0.2.0 is a released
  desktop version, and there is no deploy step that can reach an installed copy's
  snapshot files. The vocabulary-coverage fixture test
  (`test/.../snapshot_vocabulary_test.exs`) is what makes forgetting the entry
  impossible: it decodes a committed payload written under the old vocabulary, so
  a retirement without a rename entry turns CI red.
  """

  @modules [
    ArmchairMetropolist.Domain.Entities.CityMap,
    ArmchairMetropolist.Domain.Entities.MunicipalBond,
    ArmchairMetropolist.Domain.Entities.Node
  ]

  # Retired node-type atoms and their successors. The literal keys are load-bearing
  # twice over: they intern the retired atoms (so `:safe` decodes accept them), and
  # they drive the rewrite in modernize/1.
  @node_type_renames %{road_hub: :transit_hub}

  # Struct field names added to a persisted entity since the first release. Unlike
  # `@node_type_renames`, these are current vocabulary, not retired — and unlike that
  # map, this list buys nothing on its own yet: `:waste_stock` was added to `CityMap`'s
  # `defstruct` in the same commit that added it here, so `ensure_loaded!/0` already
  # interns the atom by compiling `CityMap`, whether or not this list mentions it.
  #
  # What this is, is the machinery for the two-release rollout docs/deploying.md
  # describes for the *next* field, so that rollout does not have to invent a mechanism
  # under time pressure: list a new field's atom here, in the release that will read it,
  # one release before the release that starts writing it to the struct. That earlier
  # release then decodes a payload carrying the new atom correctly — as a field it
  # does not recognise yet, defaulted by `modernize/1` — instead of `:safe` refusing to
  # create an atom that neither the struct nor this list has ever mentioned. Skipping
  # that bridge release is exactly what happened for `:waste_stock`, and rolling a
  # binary back past the commit that added it is unrecoverable either way — see
  # docs/deploying.md, "The third trap: rolling back past a new CityMap field".
  @added_fields [
    :waste_stock,
    :injury_stock,
    :disease_stock,
    :crime_stock,
    :revision,
    :municipal_bond,
    :commercial_bond
  ]

  @doc "The modules whose atoms a persisted city can contain."
  def modules, do: @modules

  @doc """
  Struct field names staged for the two-release rollout, interned by appearing here.

  Not modules, so `ensure_loaded!/0` has nothing to load for them — a bare atom
  is interned the instant this module is, which is the same reason
  `@node_type_renames`'s keys need no loader. This accessor exists so the list is
  reachable and testable rather than dead. It is not the converse of
  `@node_type_renames`'s guarantee, though: a field's presence here does not mean an
  older release can decode it — `:waste_stock` is listed, and an older release still
  cannot, because the field and this list entry shipped in the same commit. What this
  protects is the *next* field staged here a release ahead of the one that writes it.
  See docs/deploying.md, "The third trap: rolling back past a new CityMap field".
  """
  def added_fields, do: @added_fields

  @doc "Interns every atom a persisted city can legitimately contain."
  def ensure_loaded! do
    Enum.each(@modules, &Code.ensure_loaded!/1)
  end

  @doc """
  Rewrite a freshly decoded city into the current vocabulary.

  Applies `@node_type_renames` to every node, so a snapshot written before a
  rename hydrates as though it had been written after it. A city already in the
  current vocabulary passes through unchanged. Called by both snapshot adapters
  immediately after their `:safe` decode — a city that skips this carries retired
  atoms into the domain, where `Node.capacity/1` raises on them. It also supplies
  defaults for struct fields added since the payload was written, so an older
  city hydrates with the same fields a fresh one gets rather than raising
  `KeyError` the first time something reads the new field.
  """
  def modernize(%{nodes: nodes} = city_map) when is_map(nodes) do
    # `Map.put_new`, not the `%{map | key: value}` update syntax: that syntax
    # requires the key to already exist, which is exactly what an older payload
    # does not have. And not `Map.put` either — see the test that seeds a city
    # with a real backlog, which a `put` would silently reset to zero on every
    # hydrate.
    city_map
    |> Map.put_new(:waste_stock, 0.0)
    |> Map.put_new(:injury_stock, 0.0)
    |> Map.put_new(:disease_stock, 0.0)
    |> Map.put_new(:crime_stock, 0.0)
    |> Map.put_new(:revision, 0)
    |> Map.put_new(
      :municipal_bond,
      ArmchairMetropolist.Domain.Entities.MunicipalBond.legacy()
    )
    |> Map.put_new(:commercial_bond, nil)
    |> Map.put(:nodes, Map.new(nodes, fn {id, node} -> {id, rename_type(node)} end))
  end

  defp rename_type(%{type: type} = node) do
    %{node | type: Map.get(@node_type_renames, type, type)}
  end
end
