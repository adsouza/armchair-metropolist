defmodule ArmchairMetropolist.Domain do
  use Boundary,
    type: :strict,
    deps: [],
    exports: [
      Entities.CityMap,
      Entities.Node,
      Entities.SimulationMetrics,
      Ports.SnapshotRepository,
      Ports.Notifier
    ]
end
