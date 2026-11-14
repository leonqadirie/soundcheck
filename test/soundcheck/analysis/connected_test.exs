defmodule Soundcheck.Analysis.ConnectedTest do
  use ExUnit.Case, async: true

  alias Soundcheck.Analysis.Connected

  defp outcomes(source) do
    condition = Code.string_to_quoted!(source)
    {Connected.outcome(condition, false), Connected.outcome(condition, true)}
  end

  defp reachable(source, connected?) do
    source
    |> Code.string_to_quoted!()
    |> Connected.reachable(connected?)
    |> Enum.map(&Macro.to_string/1)
  end

  test "connected?/1 and its negations take the value of the run" do
    assert outcomes("connected?(socket)") == {false, true}
    assert outcomes("Phoenix.LiveView.connected?(socket)") == {false, true}
    assert outcomes("not connected?(socket)") == {true, false}
    assert outcomes("!!connected?(socket)") == {false, true}
    assert outcomes("flag?()") == {:either, :either}
    assert outcomes("not flag?()") == {:either, :either}
  end

  test "a conjunction is false in the run where one operand is false" do
    for source <- [
          "connected?(socket) and flag?()",
          "flag?() and connected?(socket)",
          "connected?(socket) && flag?()",
          "a?() and (connected?(socket) and b?())"
        ] do
      assert outcomes(source) == {false, :either}, source
    end

    assert outcomes("not connected?(socket) and flag?()") == {:either, false}
    assert outcomes("not (connected?(socket) and flag?())") == {true, :either}
    assert outcomes("connected?(socket) and connected?(socket)") == {false, true}
  end

  test "a disjunction is true in the run where one operand is true" do
    for source <- ["connected?(socket) or flag?()", "flag?() || connected?(socket)"] do
      assert outcomes(source) == {:either, true}, source
    end

    assert outcomes("!connected?(socket) or flag?()") == {true, :either}
    assert outcomes("a?() or b?()") == {:either, :either}
  end

  test "reachable/2 drops the operands a decided connective skips" do
    assert reachable("connected?(socket) and flag?()", false) == ["connected?(socket)"]
    assert reachable("connected?(socket) and flag?()", true) == ["connected?(socket)", "flag?()"]
    assert reachable("flag?() and connected?(socket)", false) == ["flag?()", "connected?(socket)"]
    assert reachable("connected?(socket) or flag?()", true) == ["connected?(socket)"]
    assert reachable("not (a?() || b?())", false) == ["a?()", "b?()"]
  end
end
