defmodule Soundcheck.Check.Warning.UndefinedHookTest do
  use Soundcheck.CheckCase

  import Soundcheck.HeexCase, only: [text_at: 2]

  alias Soundcheck.Analysis.Hooks
  alias Soundcheck.Check.Warning.UndefinedHook
  alias Soundcheck.Graph

  @js [js_paths: ["test/support/fixtures/assets/js"]]

  @source ~S'''
  defmodule MyAppWeb.FeedLive do
    use MyAppWeb, :live_view

    def render(assigns) do
      ~H"""
      <div id="feed" phx-hook="InfiniteScroll"></div>
      <div id="typo" phx-hook="InfiniteScrol"></div>
      <div id="chart" phx-hook="Chart"></div>
      <div id="copy" phx-hook="Copy"></div>
      <div id="local" phx-hook=".Local"></div>
      <div id="missing-local" phx-hook=".Missing"></div>
      <div id="dynamic" phx-hook={@hook}></div>
      <script :type={Phoenix.LiveView.ColocatedHook} name=".Local">
        export default { mounted() { this.pushEvent("local-ready") } }
      </script>
      """
    end
  end
  '''

  test "the registry follows local objects, relative imports, and colocated hooks" do
    graph = Graph.build(inputs(@source), @js)
    registry = Hooks.registry(graph)

    assert registry.socket?
    assert registry.open == []

    assert registry.names |> Map.keys() |> Enum.sort() ==
             ["Chart", "Copy", "InfiniteScroll", "MyAppWeb.FeedLive.Local"]
  end

  test "the registry follows qualified constructors, namespace imports, and imported bindings" do
    graph = Graph.build(inputs(@source), js_paths: ["test/support/fixtures/assets/qualified_js"])
    registry = Hooks.registry(graph)

    assert registry.open == []

    assert registry.names |> Map.keys() |> Enum.sort() ==
             ["Assigned", "Classy", "Default", "Named"]

    assert {:ok, %{pushes: [%{event: {:literal, "named-ready"}}]}} =
             Hooks.events(graph, registry.names["Named"])

    assert {:ok, %{pushes: [%{event: {:literal, "assigned-ready"}}]}} =
             Hooks.events(graph, registry.names["Assigned"])
  end

  test "fires on unregistered hooks, including colocated names" do
    diagnostics = analyze(UndefinedHook, @source, [], @js)

    assert Enum.map(diagnostics, &text_at(@source, &1.primary)) == ["InfiniteScrol", ".Missing"]
    assert [typo, missing] = diagnostics
    assert typo.suggestion == ~S|Did you mean "InfiniteScroll"?|
    assert typo.resolution == :resolved
    assert missing.message =~ ~S|"MyAppWeb.FeedLive.Missing"|
  end

  test "without a LiveSocket, findings are unverifiable" do
    assert [_, _ | _] = diagnostics = analyze(UndefinedHook, @source)
    assert Enum.all?(diagnostics, &(&1.resolution == {:unverifiable, :no_live_socket}))
  end

  test "external_hooks are known and close an open registry" do
    diagnostics = analyze(UndefinedHook, @source, [external_hooks: ["InfiniteScrol"]], @js)
    assert [missing] = diagnostics
    assert missing.message =~ "Missing"
  end
end
