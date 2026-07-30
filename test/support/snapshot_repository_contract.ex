defmodule ArmchairMetropolist.SnapshotRepositoryContract do
  @moduledoc "Shared assertions every SnapshotRepository adapter must satisfy."

  defmacro __using__(adapter: adapter) do
    quote do
      alias ArmchairMetropolist.Domain.Entities.{CityMap, Node}

      @adapter unquote(adapter)

      defp sample_city do
        CityMap.new(40, 30)
        |> CityMap.put_node(Node.new(1, 1, :power_plant))
        |> CityMap.put_node(%Node{Node.new(2, 2, :residential) | health: 42.5, status: :degraded})
      end

      test "returns :not_found when nothing is stored" do
        assert {:error, :not_found} = @adapter.load_latest()
      end

      test "round-trips a city map" do
        city = sample_city()
        assert :ok = @adapter.save(7, city)
        assert {:ok, {7, loaded}} = @adapter.load_latest()
        assert loaded == city
      end

      test "returns the most recent snapshot" do
        assert :ok = @adapter.save(1, sample_city())
        assert :ok = @adapter.save(9, CityMap.new(10, 10))
        assert {:ok, {9, loaded}} = @adapter.load_latest()
        assert loaded.width == 10
      end

      test "save/2 returns bare :ok, not {:ok, id}" do
        assert :ok === @adapter.save(3, sample_city())
      end
    end
  end
end
