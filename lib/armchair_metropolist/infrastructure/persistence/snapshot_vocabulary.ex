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
    ArmchairMetropolist.Domain.Entities.Node
  ]

  # Retired node-type atoms and their successors. The literal keys are load-bearing
  # twice over: they intern the retired atoms (so `:safe` decodes accept them), and
  # they drive the rewrite in modernize/1.
  @node_type_renames %{road_hub: :transit_hub}

  # Struct field names added to a persisted entity since the first release. Unlike
  # `@node_type_renames`, these are current vocabulary, not retired — but they are
  # just as load-bearing: rolling an older binary back past the commit that added
  # one means it decodes a snapshot containing the atom without ever having loaded
  # the module version that defines it, and `:safe` refuses to create it from
  # scratch. Listing it here interns it explicitly, rather than relying on
  # `CityMap` happening to already be compiled with the field. See
  # docs/deploying.md, "The third trap: rolling back past a new CityMap field".
  @added_fields [:waste_stock]

  @doc "The modules whose atoms a persisted city can contain."
  def modules, do: @modules

  @doc "Interns every atom a persisted city can legitimately contain."
  def ensure_loaded! do
    Enum.each(@modules, &Code.ensure_loaded!/1)

    # `@added_fields` lists struct field names, not modules — there is nothing to
    # `Code.ensure_loaded!/1` for a plain atom. It is already interned simply by
    # appearing as a literal in this module's own compiled code, true the instant
    # `SnapshotVocabulary` itself is loaded (the same reason `@node_type_renames`'s
    # keys need no loader either). Reading it here keeps it wired into a real code
    # path instead: an attribute nothing reads is a compiler warning in this
    # project, and dead code a later edit could delete without anyone noticing.
    Enum.each(@added_fields, &Function.identity/1)
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
    |> Map.put(:nodes, Map.new(nodes, fn {id, node} -> {id, rename_type(node)} end))
  end

  defp rename_type(%{type: type} = node) do
    %{node | type: Map.get(@node_type_renames, type, type)}
  end
end
