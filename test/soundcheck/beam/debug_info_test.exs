defmodule Soundcheck.Beam.DebugInfoTest do
  use ExUnit.Case, async: false

  alias Soundcheck.Beam.DebugInfo
  alias Soundcheck.Cache
  alias SoundcheckFixtures.CounterLive

  setup do
    Cache.clear()
    :ok
  end

  # Expansion turns `"row-" <> id` into a binary pattern and `event in [...]`
  # into an `orelse` chain of `=:=` comparisons; handler matching reads
  # these shapes.
  test "returns expanded handle_event clauses" do
    {:ok, [inc, row, guarded]} = DebugInfo.clauses(CounterLive, :handle_event, 3)

    assert {_meta, ["inc" | _], [], _body} = inc

    assert {_meta, [{:<<>>, _, [{:"::", _, ["row-", _]}, {:"::", _, [{:_id, _, nil}, _]}]} | _],
            [], _body} = row

    assert {meta, [{:event, _, nil} | _], [guard], _body} = guarded
    assert is_integer(meta[:line])

    assert {{:., _, [:erlang, :orelse]}, _,
            [
              {{:., _, [:erlang, :"=:="]}, _, [{:event, _, nil}, "reset"]},
              {{:., _, [:erlang, :"=:="]}, _, [{:event, _, nil}, "clear"]}
            ]} = guard
  end

  test "returns the source file" do
    {:ok, %{file: file}} = DebugInfo.definitions(CounterLive)
    assert String.ends_with?(file, "test/support/fixtures/live.ex")
  end

  test "returns no clauses for an undefined function" do
    assert {:ok, []} = DebugInfo.clauses(CounterLive, :handle_info, 2)
  end

  test "reports modules compiled without debug info" do
    assert {:error, :no_debug_info} = DebugInfo.definitions(SoundcheckFixtures.NoDebugInfo)
  end

  test "reports modules that cannot be loaded" do
    assert {:error, :not_loadable} = DebugInfo.definitions(SoundcheckFixtures.DoesNotExist)
  end
end
