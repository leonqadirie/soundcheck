defmodule Soundcheck.Check.EventPayloadMismatchTest do
  use Soundcheck.CheckCase

  import Soundcheck.HeexCase, only: [text_at: 2]

  alias Soundcheck.Check.Warning.EventPayloadMismatch
  alias Soundcheck.Graph
  alias Soundcheck.Graph.Link
  alias Soundcheck.Rule

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

  test "many calls do not copy their full template into the render index" do
    calls = 100
    padding = String.duplicate("x", 100_000)

    rendered_calls =
      Enum.map_join(1..calls, "\n", fn _ -> ~s|<.save_button label="Save" />| end)

    source = """
    defmodule SoundcheckFixtures.EventPayloadCallsLive do
      use Phoenix.LiveView
      import SoundcheckFixtures.EventComponents

      def render(assigns) do
        ~H\"\"\"
        #{padding}
        #{rendered_calls}
        \"\"\"
      end
    end
    """

    graph =
      [
        {"lib/event_payload_calls_live.ex", source},
        {"lib/event_components.ex", File.read!("test/support/fixtures/events.ex")}
      ]
      |> inputs()
      |> Graph.build(js_paths: [])
      |> Link.link(EventPayloadMismatch.needs())

    index = Graph.render_index(graph)

    template =
      Enum.find(
        graph.templates,
        &(&1.owner == {SoundcheckFixtures.EventPayloadCallsLive, :render})
      )

    bytes = fn term -> :erts_debug.flat_size(term) * :erlang.system_info(:wordsize) end

    assert bytes.(index) < bytes.(template) * 3

    params = EventPayloadMismatch.param_defaults()
    diagnostics = Rule.run(EventPayloadMismatch, graph, params)

    assert [diagnostic] = diagnostics
    assert diagnostic.primary.file == "lib/event_components.ex"
    assert diagnostic.primary.start == {7, 55}
    assert diagnostic.message =~ ~s(`phx-click="save"` sends no "id")
    assert diagnostic.message =~ "`SoundcheckFixtures.EventPayloadCallsLive`"
  end
end
