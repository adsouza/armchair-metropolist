defmodule ArmchairMetropolist.Infrastructure.Persistence.SnapshotReaper do
  @moduledoc """
  Deletes cities nobody has touched for `:snapshot_retention_days`.

  Server target only. The desktop target has exactly one city that must never be
  reaped, and no scheduler to run this on.

  Sweeps once on boot and then every `:snapshot_sweep_interval_ms`. `sweep/0` is
  public and synchronous so tests can drive it without waiting a day.
  """

  use GenServer

  import Ecto.Query

  alias ArmchairMetropolist.Infrastructure.Persistence.CitySnapshot
  alias ArmchairMetropolist.Infrastructure.Persistence.Repo

  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Delete every city whose `updated_at` is older than the retention window.

  Returns the number deleted. It is logged as well as returned: a sweep that
  removes data should say so, or nobody notices the day it removes the wrong amount.
  """
  def sweep do
    days = config(:snapshot_retention_days, 90)
    cutoff = NaiveDateTime.utc_now() |> NaiveDateTime.add(-days * 24 * 60 * 60, :second)

    {deleted, _} =
      Repo.delete_all(from(s in CitySnapshot, where: s.updated_at < ^cutoff))

    if deleted > 0 do
      Logger.info("[reaper] deleted #{deleted} cities untouched since #{cutoff}")
    end

    {:ok, deleted}
  end

  @impl true
  def init(_opts) do
    {:ok, %{}, {:continue, :sweep}}
  end

  @impl true
  def handle_continue(:sweep, state) do
    sweep()
    {:noreply, schedule(state)}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    {:noreply, schedule(state)}
  end

  defp schedule(state) do
    Process.send_after(self(), :sweep, config(:snapshot_sweep_interval_ms, 86_400_000))
    state
  end

  defp config(key, default), do: Application.get_env(:armchair_metropolist, key, default)
end
