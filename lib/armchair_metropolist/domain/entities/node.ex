defmodule ArmchairMetropolist.Domain.Entities.Node do
  @moduledoc "A single piece of placed city infrastructure."

  @type resource :: :power | :water | :waste | :traffic
  @type node_type ::
          :power_plant | :water_plant | :industrial | :road_hub
          | :residential | :commercial | :park
  @type status :: :online | :degraded | :offline

  @type t :: %__MODULE__{
          id: String.t(),
          x: non_neg_integer(),
          y: non_neg_integer(),
          type: node_type(),
          health: float(),
          status: status()
        }

  defstruct [:id, :x, :y, :type, :health, :status]
end
