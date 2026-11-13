defmodule Soundcheck.Analysis.AssignsTest do
  use Soundcheck.CheckCase

  alias Soundcheck.Analysis.Assigns
  alias Soundcheck.Graph
  alias Soundcheck.Heex.Parser

  # Interprets a `mount/3` with the given body for one context.
  defp mount(body, connected? \\ false) do
    source = """
    defmodule AssignsTestLive do
      use Phoenix.LiveView

      def mount(params, _session, socket) do
    #{body}
      end
    end
    """

    graph = Graph.build(inputs(source), js_paths: [])
    clauses = Map.fetch!(Graph.module(graph, AssignsTestLive).functions, {:mount, 3})
    Assigns.mount(clauses, connected?)
  end

  defp must(result), do: Enum.sort(result.must)
  defp may(result), do: Enum.sort(result.may)

  describe "mount/2 key arguments" do
    test "an atom value names no key" do
      result =
        mount("""
        socket = assign(socket, :mode, :short)
        {:ok, socket |> assign(:tone, :neutral) |> assign_new(:kind, :card)}
        """)

      assert must(result) == [:kind, :mode, :tone]
    end

    test "reads the atom list of assign_async/3" do
      result = mount("{:ok, assign_async(socket, [:profile, :stats], fn -> {:ok, %{}} end)}")

      assert must(result) == [:profile, :stats]
    end

    test "a variable in place of the key opens the result" do
      assert mount("{:ok, assign(socket, key, :value)}").open?
      assert mount("{:ok, assign(socket, extra)}").open?
    end
  end

  describe "literal_keys/1" do
    test "reads the key argument after the socket and leaves the value alone" do
      [_assign | args] = quote(do: [assign, socket, :mode, :short])
      assert Assigns.literal_keys(args) == [:mode]
    end

    test "reads the key argument of a piped call" do
      assert Assigns.literal_keys([:mode, :short]) == [:mode]
      assert Assigns.literal_keys([[mode: :short, tone: :neutral]]) == [:mode, :tone]
    end

    test "nil, booleans, maps, and variables name no key" do
      socket = quote(do: socket)

      assert Assigns.literal_keys([socket, nil, :value]) == []
      assert Assigns.literal_keys([socket, true]) == []
      assert Assigns.literal_keys([socket, quote(do: %{mode: :short})]) == []
      assert Assigns.literal_keys([socket, quote(do: key), :value]) == []
    end
  end
end
