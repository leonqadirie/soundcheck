defmodule Soundcheck.Graph.LinkTest do
  use ExUnit.Case, async: true

  alias Soundcheck.Graph
  alias Soundcheck.Graph.Input
  alias Soundcheck.Graph.Link

  # The graph of every fixture module, so each link has entries to store.
  defp fixture_graph do
    inputs =
      for file <- Path.wildcard("test/support/fixtures/**/*.ex") do
        {:ok, input} = Input.parse(file, File.read!(file))
        input
      end

    Graph.build(inputs, js_paths: ["test/support/fixtures/assets"])
  end

  setup_all do
    %{graph: fixture_graph()}
  end

  describe "compute/2" do
    # A persistent term and a task message copy every graph term a stored
    # link holds, once per reference. `:erts_debug.size/1` counts a shared
    # subterm once, so the pair is smaller than its parts when the stored
    # link holds a term of the graph.
    #
    # The test builds its own graph: the copy `setup_all` sends shares no
    # subterms, and measuring it takes several times as long.
    test "no stored link holds a term of the graph" do
      graph = fixture_graph()
      graph_words = :erts_debug.size(graph)

      sharing =
        for link <- Graph.links(),
            stored = Link.compute(link, graph),
            apart = graph_words + :erts_debug.size(stored) + tuple_words(2),
            shared = apart - :erts_debug.size({graph, stored}),
            shared > 0,
            do: {link, shared}

      assert sharing == [],
             "stored links share words with the graph: #{inspect(sharing)}; " <>
               "store names or positions and look them up in `Link.resolve/2`"
    end
  end

  describe "resolve/2" do
    test "the render index's call sites are the graph's own templates", %{graph: graph} do
      index = Graph.render_index(Link.link(graph, [:render_index]))
      sites = index.sites |> Map.values() |> List.flatten()

      assert sites != []

      for {template, element} <- sites do
        assert template in graph.templates
        assert element.kind in [:local_component, :remote_component]
      end
    end

    test "a call site's element keeps its children", %{graph: graph} do
      index = Graph.render_index(Link.link(graph, [:render_index]))
      sites = index.sites |> Map.values() |> List.flatten()

      assert Enum.any?(sites, fn {_template, element} -> element.children != [] end)
    end

    test "the live modules are the graph's own entries", %{graph: graph} do
      live_modules = Graph.live_modules(Link.link(graph, [:live_modules]))

      assert live_modules != []

      for {entry, kind} <- live_modules do
        assert entry in graph.modules
        assert kind in [:view, :component]
      end
    end
  end

  # The header word and one word per element.
  defp tuple_words(size), do: 1 + size
end
