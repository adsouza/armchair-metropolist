defmodule ArmchairMetropolistWeb.CityCodeTest do
  use ExUnit.Case, async: true

  alias ArmchairMetropolistWeb.CityCode

  test "generates 22 URL-safe characters" do
    code = CityCode.generate()

    assert String.length(code) == 22
    assert CityCode.valid?(code)
  end

  test "generates a different code each time" do
    codes = Enum.map(1..100, fn _ -> CityCode.generate() end)

    assert length(Enum.uniq(codes)) == 100
  end

  test "rejects everything outside the allowlist" do
    refute CityCode.valid?("")
    refute CityCode.valid?(String.duplicate("a", 21))
    refute CityCode.valid?(String.duplicate("a", 23))
    refute CityCode.valid?("../../etc/passwd------")
    refute CityCode.valid?("aaaaaaaaaaaaaaaaaaaa/=")
    refute CityCode.valid?("aaaaaaaaaaaaaaaaaaaa\na")

    # 22 valid characters plus a trailing newline. This is the case that justifies
    # \A and \z: ^ and $ treat a final newline as end-of-string and would accept it.
    refute CityCode.valid?(String.duplicate("a", 22) <> "\n")

    refute CityCode.valid?(nil)
    refute CityCode.valid?(:atom)
  end
end
