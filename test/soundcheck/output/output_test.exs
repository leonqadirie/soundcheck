defmodule Soundcheck.OutputTest do
  use ExUnit.Case, async: true

  alias Soundcheck.Check.Warning.UnhandledEvent
  alias Soundcheck.Diagnostic
  alias Soundcheck.Output.JSON
  alias Soundcheck.Output.SARIF
  alias Soundcheck.Output.Text
  alias Soundcheck.Span

  @file_path "test/support/fixtures/events.ex"

  defp diagnostic(overrides \\ []) do
    span = Span.new(@file_path, {34, 26}, {34, 30})

    struct!(
      %Diagnostic{
        rule: UnhandledEvent,
        id: "SC101",
        message: "`phx-click=\"incr\"` has no matching `handle_event/3` clause.",
        suggestion: ~S|Did you mean "inc"?|,
        primary: span,
        anchor: span,
        related: [{Span.new(@file_path, {44, 3}, {44, 6}), "handlers are defined here"}]
      },
      overrides
    )
  end

  test "text shows the snippet with carets, the suggestion, related locations, and a summary" do
    text = Text.render([diagnostic(), diagnostic(resolution: {:unverifiable, :css_selector})])

    assert text =~ "SC101 warning: `phx-click=\"incr\"`"
    assert text =~ " --> #{@file_path}:34:26"
    assert text =~ ~s(34 |       <button phx-click="incr">typo</button>)
    assert text =~ "   |                          ^^^^\n"
    assert text =~ ~s(= help: Did you mean "inc"?)
    assert text =~ "= note: handlers are defined here"
    assert text =~ "(unverifiable: css_selector)"
    assert String.ends_with?(text, "\n1 finding, 1 unverifiable\n")
  end

  test "json carries every location" do
    [entry] = [diagnostic()] |> JSON.render() |> Jason.decode!()

    assert %{
             "id" => "SC101",
             "resolution" => "resolved",
             "location" => %{
               "file" => @file_path,
               "line" => 34,
               "column" => 26,
               "end_column" => 30
             },
             "related" => [%{"line" => 44, "label" => "handlers are defined here"}]
           } = entry
  end

  test "sarif 2.1.0 carries rules, related locations, and levels" do
    sarif =
      [diagnostic(), diagnostic(resolution: {:unverifiable, :css_selector})]
      |> SARIF.render([UnhandledEvent])
      |> Jason.decode!()

    assert %{"version" => "2.1.0", "runs" => [run]} = sarif
    assert run["columnKind"] == "unicodeCodePoints"
    assert [%{"id" => "SC101", "name" => "UnhandledEvent"}] = run["tool"]["driver"]["rules"]

    assert [resolved, unverifiable] = run["results"]
    assert resolved["level"] == "warning"
    assert unverifiable["level"] == "note"
    assert resolved["message"]["text"] =~ ~s(Did you mean "inc"?)

    assert [%{"id" => 1, "message" => %{"text" => "handlers are defined here"}}] =
             resolved["relatedLocations"]

    assert %{"startLine" => 34, "startColumn" => 26, "endColumn" => 30} =
             hd(resolved["locations"])["physicalLocation"]["region"]
  end
end
