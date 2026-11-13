defmodule Soundcheck.Analysis.ComponentAssignsTest do
  use Soundcheck.CheckCase

  alias Soundcheck.Analysis.ComponentAssigns
  alias Soundcheck.Graph

  # The graph and index entry of a component module with the given body.
  defp module(body) do
    source = """
    defmodule ComponentAssignsTestComponents do
      use Phoenix.Component

    #{body}
    end
    """

    graph = Graph.build(inputs(source), js_paths: [])
    {graph, Graph.module(graph, ComponentAssignsTestComponents)}
  end

  # The keys a `card/1` with the given body assigns.
  defp keys(body) do
    {_graph, entry} =
      module("""
      def card(assigns) do
      #{body}
        ~H"<p></p>"
      end
      """)

    case ComponentAssigns.keys(Map.fetch!(entry.functions, {:card, 1})) do
      {:ok, keys} -> Enum.sort(keys)
      :open -> :open
    end
  end

  describe "keys/1" do
    test "reads the keys of assign, assign_new, update, and Map.put calls" do
      assert keys("""
             assigns =
               assigns
               |> assign(:title, "x")
               |> assign(size: 1, tone: 2)
               |> assign_new(:icon, fn -> nil end)
               |> update(:class, &List.wrap/1)

             assigns = Map.put(assigns, :id, "card")
             """) == [:class, :icon, :id, :size, :title, :tone]
    end

    test "reads the keys of remote assigning calls" do
      assert keys("assigns = Phoenix.Component.assign(assigns, :title, 1)") == [:title]
    end

    test "an atom value names no key" do
      assert keys("""
             assigns = assign(assigns, :tone, :neutral)
             assigns = assigns |> assign(:size, :small) |> Map.put(:kind, :card)
             """) == [:kind, :size, :tone]
    end

    test "a map or variable in place of the key opens the result" do
      assert keys("assigns = assign(assigns, extra)") == :open
      assert keys("assigns = assign(assigns, key, :value)") == :open
    end

    test "Map.merge and rebinding assigns through another function open the result" do
      assert keys("assigns = Map.merge(assigns, %{title: 1})") == :open
      assert keys("assigns = normalize(assigns)") == :open
      assert keys("assigns = assigns |> assign(:title, 1) |> normalize()") == :open
    end

    test "near miss: binding another variable keeps the result closed" do
      assert keys("""
             rows = normalize(assigns.rows)
             assigns = assign(assigns, :rows, rows)
             """) == [:rows]
    end
  end

  describe "head_keys/2" do
    setup do
      {graph, entry} =
        module(~S'''
        def link(%{href: _href, kind: :external} = assigns), do: ~H"<a>external</a>"
        def link(assigns), do: ~H"<a>internal</a>"
        ''')

      templates = graph |> Graph.templates_of(entry.name, :link) |> Enum.sort_by(& &1.id)
      %{clauses: Map.fetch!(entry.functions, {:link, 1}), templates: templates}
    end

    test "lists the keys the clause holding the template matches", context do
      %{clauses: clauses, templates: [external, internal]} = context

      assert Enum.sort(ComponentAssigns.head_keys(clauses, external)) == [:href, :kind]
      assert Enum.sort(ComponentAssigns.head_keys(clauses, internal)) == []
    end

    test "a template file belongs to no single clause", context do
      %{clauses: clauses, templates: [external, _internal]} = context

      assert Enum.sort(ComponentAssigns.head_keys(clauses, %{external | origin: :file})) == []
    end
  end

  describe "live_render?/2" do
    test "a LiveView's or LiveComponent's render/1 reads socket assigns" do
      assert ComponentAssigns.live_render?(%{kind: :live_view, functions: %{}}, :render)
      assert ComponentAssigns.live_render?(%{kind: :live_component, functions: %{}}, :render)
    end

    test "so does the render/1 of a module that defines a LiveView callback" do
      {_graph, entry} =
        module("""
        def mount(_params, _session, socket), do: {:ok, socket}
        def render(assigns), do: ~H"<p></p>"
        """)

      assert ComponentAssigns.live_render?(entry, :render)
    end

    test "near miss: a function component named render, and any other function" do
      {_graph, entry} = module(~S|def render(assigns), do: ~H"<p></p>"|)

      refute ComponentAssigns.live_render?(entry, :render)
      refute ComponentAssigns.live_render?(%{kind: :live_view, functions: %{}}, :card)
    end
  end
end
