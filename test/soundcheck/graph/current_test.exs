defmodule Soundcheck.Graph.CurrentTest do
  use Soundcheck.CheckCase, async: false

  alias Soundcheck.Graph

  test "get/1 returns the run's graph with only the links a check needs" do
    Graph.Current.prepare(inputs("defmodule A do\nend\n"), js_paths: [])

    graph = Graph.Current.get([:live_modules, :routes])

    assert graph.live_modules == []
    assert graph.routes == []
    assert graph.render_index == :not_linked
    assert graph.js_helpers == :not_linked
  end
end
