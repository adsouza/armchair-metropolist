defmodule ArmchairMetropolist.Infrastructure.Persistence.FileSnapshotStore do
  @moduledoc "File-based adapter implementing the SnapshotRepository port."

  @behaviour ArmchairMetropolist.Domain.Ports.SnapshotRepository

  @primary_filename "snapshot.bin"
  @backup_filename "snapshot.bak"
  @tmp_filename "snapshot.tmp"

  # Every atom a stored city can contain is defined by one of these two modules:
  # CityMap's struct keys, and Node's struct keys plus the node-type, resource and
  # status vocabularies. See ensure_vocabulary_loaded/0.
  @vocabulary [
    ArmchairMetropolist.Domain.Entities.CityMap,
    ArmchairMetropolist.Domain.Entities.Node
  ]

  @impl true
  def load_latest do
    ensure_vocabulary_loaded()

    with {:error, _reason} <- read_snapshot(primary_path()),
         {:error, _reason} <- read_snapshot(backup_path()) do
      {:error, :not_found}
    end
  end

  @impl true
  def save(tick, city_map) do
    payload = :erlang.term_to_binary(city_map, [:compressed])
    checksum = :crypto.hash(:md5, payload) |> Base.encode16()

    envelope = %{version: 1, tick: tick, checksum: checksum, payload: payload}
    encoded = :erlang.term_to_binary(envelope)

    tmp_path = tmp_path()
    primary_path = primary_path()
    backup_path = backup_path()

    File.write!(tmp_path, encoded)

    if File.exists?(primary_path) do
      File.rename!(primary_path, backup_path)
    end

    File.rename!(tmp_path, primary_path)

    :ok
  end

  defp read_snapshot(path) do
    with {:ok, encoded} <- File.read(path),
         {:ok, envelope} <- safe_binary_to_term(encoded),
         {:ok, city_map} <- decode(envelope) do
      {:ok, {envelope.tick, city_map}}
    end
  end

  # `:safe` refuses to create atoms that do not already exist, and a stored city is
  # made of them — node types, resource names, statuses, every struct key. The
  # engine hydrates before anything else has touched the domain entities, so on a
  # cold VM those modules are not loaded, their atoms are absent, and the decode
  # below raises. `read_snapshot/1` would then rescue it into `{:error, :malformed}`
  # and `load_latest/0` into `{:error, :not_found}` — a saved city discarded in
  # silence, and only on the runs where nothing happened to load the modules first
  # (a preceding `mix compile` is enough to hide it).
  #
  # Loading the vocabulary first interns every atom the payload can legitimately
  # contain. `:safe` keeps doing its actual job: rejecting a payload that carries
  # anything else.
  defp ensure_vocabulary_loaded do
    Enum.each(@vocabulary, &Code.ensure_loaded!/1)
  end

  defp safe_binary_to_term(encoded) do
    {:ok, :erlang.binary_to_term(encoded, [:safe])}
  rescue
    ArgumentError -> {:error, :malformed}
  end

  defp decode(%{checksum: checksum, payload: payload}) do
    if :crypto.hash(:md5, payload) |> Base.encode16() == checksum do
      {:ok, :erlang.binary_to_term(payload, [:safe])}
    else
      {:error, :checksum_mismatch}
    end
  rescue
    ArgumentError -> {:error, :malformed}
  end

  defp decode(_other), do: {:error, :malformed}

  defp primary_path, do: Path.join(snapshot_dir(), @primary_filename)
  defp backup_path, do: Path.join(snapshot_dir(), @backup_filename)
  defp tmp_path, do: Path.join(snapshot_dir(), @tmp_filename)

  defp snapshot_dir do
    Application.get_env(:armchair_metropolist, :snapshot_dir)
  end
end
