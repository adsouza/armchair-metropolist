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
  """

  @modules [
    ArmchairMetropolist.Domain.Entities.CityMap,
    ArmchairMetropolist.Domain.Entities.Node
  ]

  @doc "The modules whose atoms a persisted city can contain."
  def modules, do: @modules

  @doc "Interns every atom a persisted city can legitimately contain."
  def ensure_loaded! do
    Enum.each(@modules, &Code.ensure_loaded!/1)
  end
end
