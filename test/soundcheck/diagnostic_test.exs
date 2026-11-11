defmodule Soundcheck.DiagnosticTest do
  use ExUnit.Case, async: true

  alias Soundcheck.Check.Warning.UnhandledEvent
  alias Soundcheck.Diagnostic
  alias Soundcheck.Span

  @span Span.new("lib/demo.ex", {1, 1}, {1, 5})

  test "new/4 takes id and confidence from the rule and anchors at the primary span" do
    assert %Diagnostic{id: "SC101", confidence: :high, anchor: @span, resolution: :resolved} =
             Diagnostic.new(UnhandledEvent, @span, "message")
  end

  test "new/4 accepts a known unverifiable reason" do
    assert %Diagnostic{resolution: {:unverifiable, :css_selector}} =
             Diagnostic.new(UnhandledEvent, @span, "message",
               resolution: {:unverifiable, :css_selector}
             )
  end

  test "new/4 rejects an unknown unverifiable reason" do
    assert_raise ArgumentError, "unknown unverifiable reason: :css_selectr", fn ->
      Diagnostic.new(UnhandledEvent, @span, "message", resolution: {:unverifiable, :css_selectr})
    end
  end
end
