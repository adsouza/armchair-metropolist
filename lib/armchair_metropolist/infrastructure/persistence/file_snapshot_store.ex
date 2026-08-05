defmodule ArmchairMetropolist.Infrastructure.Persistence.FileSnapshotStore do
  @moduledoc """
  File-based adapter implementing the SnapshotRepository port.

  Two snapshots are kept — a primary and a backup — so a write interrupted
  mid-flight cannot leave the desktop target with no readable city at all.

  ## Ordering: highest tick wins

  `load_current/0` reads *both* files and returns whichever holds the **higher
  tick**, not whichever was written most recently. This matches the port's
  intent: `save/3` takes the tick precisely so storage can order by it.

  `save/3` honours the port's staleness guarantee at that level: it consults
  `load_current/0` first and returns `{:stale, stored}` without touching disk when
  a tick at least as high is already stored, rather than writing and letting a
  stale snapshot sit unread. `save_current/2` — the renamed original body, called
  only once `save/3` has decided the write is not stale — keeps its own,
  narrower guard: a tick *older* than the primary's is accepted and reported `:ok`
  without replacing the primary or rotating the backup. The two guards cannot
  disagree, because the backup can never hold a tick higher than a readable
  primary — `save_current/2` only ever rotates a primary out once a strictly
  newer or equal tick has been accepted, so `load_current/0`'s max is always the
  primary's.

  Without the older-tick refusal above, one transient load miss was permanently
  destructive: the engine would start a fresh city at tick 0, `terminate/2` would
  write it, the real city would be demoted to the backup, and the next launch
  would overwrite the backup too.

  That older-tick refusal is `save/3`'s and, one level down, `save_current/2`'s.
  The *equal*-tick case differs between them: `save/3` refuses an equal tick just
  as it refuses a lower one, per the port's guarantee. `save_current/2` itself,
  called directly rather than through the port, has the narrower rule its own
  "re-saving the same tick overwrites in place" test exercises: equal ticks *do*
  overwrite there, so a direct re-save at the current tick behaves as a plain
  update rather than being silently dropped.

  ## Failures are returned, never raised

  Every path honours the port's `:ok | {:error, term()}`. The bang variants this
  module used to call turned a read-only snapshot directory into a raise inside
  `CityEngine.handle_info/2`, which restarted the engine and rolled its state
  back to the last checkpoint — trading one lost snapshot for fifty lost ticks.
  """

  @behaviour ArmchairMetropolist.Domain.Ports.SnapshotRepository

  alias ArmchairMetropolist.Infrastructure.Persistence.SnapshotVocabulary

  @primary_filename "snapshot.bin"
  @backup_filename "snapshot.bak"
  @tmp_filename "snapshot.tmp"

  # The city id is accepted and ignored. This adapter backs the desktop target, which
  # has exactly one city and one pair of files; honouring the id would mean a file per
  # city for a application that can only ever show one. The port's shape is shared, the
  # semantics are not.
  @impl true
  def load(_city_id), do: load_current()

  # Honours the port's staleness guarantee by declining the write, where before a stale
  # save landed on the primary and `load_current/0`'s max_by(tick) simply ignored it.
  # Observably identical through `load/1`, and strictly better on disk: refusing the
  # write also leaves the backup in place instead of rotating a newer snapshot out of it.
  @impl true
  def save(_city_id, tick, city_map) do
    case load_current() do
      {:ok, {stored, _city_map}} when stored >= tick -> {:stale, stored}
      _ -> save_current(tick, city_map)
    end
  end

  def load_current do
    # Mandatory before any `:safe` decode below, and the reason is not obvious —
    # see SnapshotVocabulary. Without it a saved city is discarded in silence.
    SnapshotVocabulary.ensure_loaded!()

    # Both files are candidates and the higher tick wins. Enum.max_by/2 keeps the
    # first of equal ticks, so a healthy primary is preferred over its own backup.
    readable =
      [primary_path(), backup_path()]
      |> Enum.map(&read_snapshot/1)
      |> Enum.flat_map(fn
        {:ok, snapshot} -> [snapshot]
        {:error, _reason} -> []
      end)

    case readable do
      [] -> {:error, :not_found}
      snapshots -> {:ok, Enum.max_by(snapshots, fn {tick, _city_map} -> tick end)}
    end
  end

  def save_current(tick, city_map) do
    if stale?(tick) do
      # A strictly newer city is already stored. See "Ordering" above.
      :ok
    else
      payload = :erlang.term_to_binary(city_map, [:compressed])
      envelope = %{version: 1, tick: tick, checksum: checksum(payload), payload: payload}

      write_snapshot(:erlang.term_to_binary(envelope))
    end
  end

  # Writes through a temp file so the primary is only ever replaced by a complete
  # snapshot. The `with` returns the first `{:error, posix}` untouched, which is
  # already the shape the port asks for.
  # sobelow_skip ["Traversal.FileModule"]
  # The path comes from `:snapshot_dir` config, never from a request. No user input
  # reaches any of the path helpers in this module.
  defp write_snapshot(encoded) do
    primary_path = primary_path()
    tmp_path = tmp_path()

    with :ok <- File.write(tmp_path, encoded),
         :ok <- rotate_primary(primary_path, backup_path()) do
      File.rename(tmp_path, primary_path)
    end
  end

  defp rotate_primary(primary_path, backup_path) do
    if File.exists?(primary_path) do
      File.rename(primary_path, backup_path)
    else
      :ok
    end
  end

  # Only the primary is consulted. The backup is by construction the primary's
  # predecessor, so it cannot hold a higher tick than a readable primary; and an
  # *unreadable* primary must not be allowed to block writes forever.
  defp stale?(tick) do
    case stored_tick(primary_path()) do
      {:ok, stored_tick} -> stored_tick > tick
      :error -> false
    end
  end

  # The envelope's tick, without decoding the compressed city payload. A snapshot
  # that fails its checksum has no trustworthy tick to compare against.
  # sobelow_skip ["Traversal.FileModule"]
  defp stored_tick(path) do
    with {:ok, encoded} <- File.read(path),
         {:ok, %{tick: tick, checksum: checksum, payload: payload}} <-
           safe_binary_to_term(encoded),
         true <- checksum(payload) == checksum do
      {:ok, tick}
    else
      _unusable -> :error
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_snapshot(path) do
    with {:ok, encoded} <- File.read(path),
         {:ok, envelope} <- safe_binary_to_term(encoded),
         {:ok, city_map} <- decode(envelope) do
      {:ok, {envelope.tick, city_map}}
    end
  end

  # sobelow_skip ["Misc.BinToTerm"]
  # Sobelow flags every `binary_to_term`, `:safe` or not, and it is right to: `:safe`
  # stops atom, pid and function creation but not a deliberately huge or deeply
  # nested term. Accepted here because the input is this application's own snapshot
  # file, not anything a user submits — an attacker able to write these bytes already
  # has write access to the app-data directory, at which point this is not the weak
  # link. Note the checksum is a *corruption* check, not a tamper one: it is stored
  # beside the payload, so whoever can rewrite one can rewrite the other.
  defp safe_binary_to_term(encoded) do
    {:ok, :erlang.binary_to_term(encoded, [:safe])}
  rescue
    ArgumentError -> {:error, :malformed}
  end

  # sobelow_skip ["Misc.BinToTerm"]
  # Same reasoning as safe_binary_to_term/1 above.
  defp decode(%{checksum: checksum, payload: payload}) do
    if checksum(payload) == checksum do
      # modernize/1 rewrites node types retired by a rename. On this adapter
      # that is the difference between hydrating the city and silently starting
      # over — the rescue below would fold the retired atom into :malformed,
      # and the stale envelope tick would then block every save.
      {:ok, payload |> :erlang.binary_to_term([:safe]) |> SnapshotVocabulary.modernize()}
    else
      {:error, :checksum_mismatch}
    end
  rescue
    ArgumentError -> {:error, :malformed}
  end

  defp decode(_other), do: {:error, :malformed}

  defp checksum(payload), do: :crypto.hash(:md5, payload) |> Base.encode16()

  defp primary_path, do: Path.join(snapshot_dir(), @primary_filename)
  defp backup_path, do: Path.join(snapshot_dir(), @backup_filename)
  defp tmp_path, do: Path.join(snapshot_dir(), @tmp_filename)

  defp snapshot_dir do
    Application.get_env(:armchair_metropolist, :snapshot_dir) ||
      raise ArgumentError, """
      #{inspect(__MODULE__)} requires :snapshot_dir to be configured.

      Without it every path resolves against nil and you get a FunctionClauseError
      from Path.join/2, which says nothing about the cause. Set it wherever this
      adapter is selected, e.g. in config/runtime.exs for the desktop target:

          config :armchair_metropolist, snapshot_dir: ExTauri.Paths.data_dir()

      Tests should point it at a per-test temporary directory.
      """
  end
end
