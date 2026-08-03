defmodule ArmchairMetropolistWeb.CityCode do
  @moduledoc """
  Generates and validates the code that identifies a visitor's city.

  16 random bytes, URL-safe Base64 without padding — 22 characters. The code is
  the credential: anyone holding it has the city, which is why it is generated
  from `:crypto.strong_rand_bytes/1` rather than anything derived or sequential.
  """

  # An allowlist, not a length check. The code reaches a database query and a
  # Registry key; Ecto parameterises the former and a Registry key is just a term,
  # so neither is an injection risk. The reason to validate is duller: an
  # unfiltered string would mint a garbage city, and a 10 MB path would mint a
  # 10 MB registry key.
  @pattern ~r/\A[A-Za-z0-9_-]{22}\z/

  @doc "A fresh, unguessable city code."
  def generate, do: 16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc "Whether `code` is one this application would have generated."
  def valid?(code) when is_binary(code), do: Regex.match?(@pattern, code)
  def valid?(_code), do: false
end
