defmodule ArmchairMetropolist.Domain.Services do
  use Boundary,
    top_level?: true,
    type: :strict,
    deps: [ArmchairMetropolist.Domain],
    exports: [SimulationCalculator]
end
