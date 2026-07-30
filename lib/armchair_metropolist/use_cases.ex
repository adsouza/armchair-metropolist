defmodule ArmchairMetropolist.UseCases do
  use Boundary,
    deps: [ArmchairMetropolist.Domain, ArmchairMetropolist.Domain.Services],
    exports: :all
end
