defmodule ArmchairMetropolist.Domain.Entities.SimulationMetrics do
  @moduledoc "Aggregate supply/demand and health figures for one tick."

  @type resource_stats :: %{
          supplied: float(),
          demanded: float(),
          deficit: float(),
          satisfaction: float()
        }

  @type t :: %__MODULE__{
          tick: non_neg_integer(),
          resources: %{optional(atom()) => resource_stats()},
          node_count: non_neg_integer(),
          avg_health: float(),
          offline_count: non_neg_integer()
        }

  defstruct tick: 0, resources: %{}, node_count: 0, avg_health: 0.0, offline_count: 0
end
