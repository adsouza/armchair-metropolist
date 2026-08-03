defmodule ArmchairMetropolist.Infrastructure.Simulation.CityRegistry do
  @moduledoc """
  Names and resolves the per-city engine processes.

  A `Registry` maps a city id to a running `CityEngine`, and a `DynamicSupervisor`
  starts one on demand. Both are started unconditionally by `Application` even
  though the engine and the clock are gated behind `:start_simulation` — they hold
  no state, and every path that resolves a city needs them, tests included. Gating
  them would mean every test that touches an engine had to start registry plumbing
  by hand.
  """

  @registry __MODULE__.Registry
  @supervisor __MODULE__.Supervisor

  @doc "Child specs for `Application`. Order matters: the registry names the children the supervisor starts."
  def children do
    [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, strategy: :one_for_one, name: @supervisor}
    ]
  end

  @doc "The `:via` tuple naming the engine for `city_id`."
  def via(city_id) when is_binary(city_id), do: {:via, Registry, {@registry, city_id}}

  @doc """
  Return the engine for `city_id`, starting it if it is not running.

  `{:error, {:already_started, pid}}` is a success here, which is what makes two
  simultaneous mounts of the same city safe without a lock: whichever loses the
  race is handed the winner's process.
  """
  def ensure_started(city_id) when is_binary(city_id) do
    spec = {ArmchairMetropolist.Infrastructure.Simulation.CityEngine, city_id: city_id}

    case DynamicSupervisor.start_child(@supervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The pid for `city_id`, or nil. For tests and diagnostics."
  def whereis(city_id) when is_binary(city_id) do
    case Registry.lookup(@registry, city_id) do
      [{pid, _value}] -> pid
      [] -> nil
    end
  end

  @doc "How many engines are running. For tests."
  def count, do: Registry.count(@registry)
end
