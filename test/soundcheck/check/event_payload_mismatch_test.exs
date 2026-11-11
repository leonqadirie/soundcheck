defmodule Soundcheck.Check.EventPayloadMismatchTest do
  use Soundcheck.CheckCase

  import Soundcheck.HeexCase, only: [text_at: 2]

  alias Soundcheck.Check.Warning.EventPayloadMismatch

  @fixture "test/support/fixtures/event_payloads.ex"

  defp fixture, do: [{@fixture, File.read!(@fixture)}]

  defp texts(diagnostics), do: Enum.map(diagnostics, &text_at(File.read!(@fixture), &1.primary))

  test "fires on clicks that send none of the keys every clause requires" do
    diagnostics = analyze(EventPayloadMismatch, fixture())

    assert texts(diagnostics) == ["delete", "JS.push", "open", "pick"]

    assert [missing, push, camel, pick] = Enum.map(diagnostics, & &1.message)
    assert missing =~ ~s(`phx-click="delete"` sends no "id")
    assert missing =~ "`SoundcheckFixtures.EventPayloadsLive`"
    assert push =~ ~s(`JS.push="delete"` sends no "id")
    assert camel =~ ~s(`phx-value-postId` arrives as "postid")
    assert pick =~ ~s(sends no "value")
  end

  test "near miss: phx-value and push keys, value properties, spreads, and catch-all clauses" do
    lines = analyze(EventPayloadMismatch, fixture()) |> Enum.map(&elem(&1.primary.start, 0))
    assert lines == [9, 10, 11, 17]
  end

  test "metadata_keys count as sent by every click" do
    diagnostics = analyze(EventPayloadMismatch, fixture(), metadata_keys: ["id"])
    assert texts(diagnostics) == ["open", "pick"]
  end
end
