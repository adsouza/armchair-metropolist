defmodule ArmchairMetropolist.Domain.DomainPurityTest do
  @moduledoc """
  Closes the one gap `boundary` cannot: GenServer, Agent, Task and Process
  live in the :elixir application, which boundary treats as unconditionally
  allowed. Verified empirically — `type: :strict` with `deps: []` compiles
  those calls clean.

  Reads each Domain module's compiled BEAM imports table, so aliases,
  imports and macro-generated calls cannot evade it.

  ## Why `:erlang` needs a function-level denylist

  Module-level denial is not enough, because the interesting impurities all
  compile straight to `:erlang.*`: `spawn/1`, `send/2`, `self/0` and
  `Kernel.exit/1` are `:erlang` BIFs, and `Process.monitor/1` inlines to
  `:erlang.monitor/2`. A Domain module could therefore spawn processes, send
  messages, monitor them and schedule timers with `@forbidden_modules` and
  `boundary` both silent — verified empirically before this list existed.

  `:erlang` cannot be banned wholesale: arithmetic compiles to `:erlang.+/2`,
  comparison to `:erlang.>/2`, `map_size/1` and `is_map/1` are BIFs too. So the
  ban is by function *name*, ignoring arity — which is deliberately blunt, since
  a Domain module has no legitimate reason to call anything named `spawn` or
  `send` under any arity.
  """
  use ExUnit.Case, async: true

  @forbidden_modules [
    GenServer,
    Agent,
    Task,
    Supervisor,
    Process,
    Registry,
    :ets,
    :dets,
    :timer,
    :gen_server,
    :global
  ]
  @forbidden_prefixes ["Ecto", "Phoenix", "ExTauri", "Plug"]

  # Processes, messages, timers, and VM-global side effects. Matched on name
  # only, so every arity of each is denied.
  @forbidden_erlang_functions [
    :spawn,
    :spawn_link,
    :spawn_monitor,
    :spawn_opt,
    :send,
    :self,
    :link,
    :unlink,
    :monitor,
    :demonitor,
    :send_after,
    :start_timer,
    :cancel_timer,
    :process_flag,
    :process_info,
    :exit,
    :register,
    :unregister,
    :whereis,
    :group_leader,
    :halt,
    :now
  ]

  test "no Domain module reaches OTP, Ecto, or Phoenix" do
    beams = domain_beams()

    assert beams != [], "found no Domain beam files - is the app compiled?"

    violations =
      for beam <- beams,
          {mod, imports} = imports_of(beam),
          {called, fun, arity} <- imports,
          forbidden?(called, fun),
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

  defp forbidden?(:erlang, fun), do: fun in @forbidden_erlang_functions

  defp forbidden?(called, _fun) do
    called in @forbidden_modules or
      Enum.any?(@forbidden_prefixes, fn prefix ->
        String.starts_with?(inspect(called), prefix <> ".") or inspect(called) == prefix
      end)
  end
end
