defmodule ArmchairMetropolist.Domain.DomainPurityTest do
  @moduledoc """
  Closes the one gap `boundary` cannot: GenServer, Agent, Task and Process
  live in the :elixir application, which boundary treats as unconditionally
  allowed. Verified empirically — `type: :strict` with `deps: []` compiles
  those calls clean.

  Reads each Domain module's compiled BEAM imports table, so aliases,
  imports and macro-generated calls cannot evade it.
  """
  use ExUnit.Case, async: true

  @forbidden_modules [
    GenServer, Agent, Task, Supervisor, Process, Registry,
    :ets, :dets, :timer, :gen_server, :global
  ]
  @forbidden_prefixes ["Ecto", "Phoenix", "ExTauri", "Plug"]

  test "no Domain module reaches OTP, Ecto, or Phoenix" do
    beams = domain_beams()

    assert beams != [], "found no Domain beam files - is the app compiled?"

    violations =
      for beam <- beams,
          {mod, imports} = imports_of(beam),
          {called, fun, arity} <- imports,
          forbidden?(called),
          do: "#{inspect(mod)} -> #{inspect(called)}.#{fun}/#{arity}"

    assert violations == [],
           "Domain layer must stay pure. Violations:\n  " <> Enum.join(violations, "\n  ")
  end

  defp domain_beams do
    :code.lib_dir(:armchair_metropolist)
    |> Path.join("ebin/Elixir.ArmchairMetropolist.Domain*.beam")
    |> Path.wildcard()
  end

  defp imports_of(beam) do
    {:ok, {mod, [imports: imports]}} =
      :beam_lib.chunks(String.to_charlist(beam), [:imports])

    {mod, imports}
  end

  defp forbidden?(called) do
    called in @forbidden_modules or
      Enum.any?(@forbidden_prefixes, fn prefix ->
        String.starts_with?(inspect(called), prefix <> ".") or inspect(called) == prefix
      end)
  end
end
