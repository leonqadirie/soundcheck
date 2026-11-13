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

  describe "mount/2 through pipes" do
    test "counts every assigning call of a pipeline" do
      result = mount("{:ok, socket |> assign(:title, 1) |> assign(page: 1, total: 2)}")

      assert must(result) == [:page, :title, :total]
      refute result.open?
    end

    test "a pipeline into a helper that receives the socket opens the result" do
      assert mount("{:ok, socket |> assign(:title, 1) |> load_defaults()}").open?
    end

    test "near miss: a pipeline that does not start at the socket stays closed" do
      result =
        mount("""
        rows = params |> Map.get("rows") |> normalize()
        {:ok, assign(socket, :rows, rows)}
        """)

      assert must(result) == [:rows]
      refute result.open?
    end

    test "tracks a variable bound to a piped socket" do
      result =
        mount("""
        loaded = socket |> assign(:title, 1)
        {:ok, load_defaults(loaded)}
        """)

      assert must(result) == [:title]
      assert result.open?
    end
  end

  describe "mount/2 through case and cond" do
    test "a key every case clause assigns must be set; one some assign may be" do
      result =
        mount("""
        socket =
          case params["mode"] do
            "full" -> assign(socket, mode: :full, detail: 1)
            _other -> assign(socket, :mode, :short)
          end

        {:ok, socket}
        """)

      assert must(result) == [:mode]
      assert may(result) == [:detail, :mode]
    end

    test "a case subject that assigns counts on every path" do
      result =
        mount("""
        case assign(socket, :title, 1) do
          socket -> {:ok, socket}
        end
        """)

      assert must(result) == [:title]
    end

    test "a key every cond clause assigns must be set; one some assign may be" do
      result =
        mount("""
        cond do
          params["a"] -> {:ok, assign(socket, a: 1, shared: 1)}
          true -> {:ok, assign(socket, :shared, 2)}
        end
        """)

      assert must(result) == [:shared]
      assert may(result) == [:a, :shared]
    end

    test "a case clause that navigates away does not weaken the others" do
      result =
        mount("""
        case params["id"] do
          nil -> {:ok, push_navigate(socket, to: "/")}
          id -> {:ok, assign(socket, :id, id)}
        end
        """)

      assert must(result) == [:id]
      refute result.halted?
    end
  end

  describe "mount/2 through with" do
    test "without else, a failing clause skips the body, so its keys only may be set" do
      result =
        mount("""
        socket = assign(socket, :title, 1)

        with {:ok, user} <- fetch_user(params) do
          {:ok, assign(socket, :user, user)}
        end
        """)

      assert must(result) == [:title]
      assert may(result) == [:title, :user]
    end

    test "with else, a key the body and every else clause assign must be set" do
      result =
        mount("""
        with {:ok, user} <- fetch_user(params) do
          {:ok, assign(socket, user: user, loaded?: true)}
        else
          {:error, _reason} -> {:ok, assign(socket, :user, nil)}
          :missing -> {:ok, assign(socket, :user, nil)}
        end
        """)

      assert must(result) == [:user]
      assert may(result) == [:loaded?, :user]
    end

    test "a with clause that hands the socket to a helper opens the result" do
      result =
        mount("""
        with {:ok, socket} <- authorize(socket) do
          {:ok, assign(socket, :user, 1)}
        end
        """)

      assert result.open?
    end
  end

  describe "mount/2 with connected?/1" do
    @body """
    if Phoenix.LiveView.connected?(socket),
      do: {:ok, assign(socket, :stats, 1)},
      else: {:ok, assign(socket, :placeholder, 1)}
    """

    test "a remote connected?/1 call picks the branch for the context" do
      assert must(mount(@body, true)) == [:stats]
      assert must(mount(@body, false)) == [:placeholder]
    end

    test "near miss: a negated condition that is not connected?/1 joins both branches" do
      result =
        mount("""
        if !params["skip"], do: {:ok, assign(socket, :stats, 1)}, else: {:ok, socket}
        """)

      assert must(result) == []
      assert may(result) == [:stats]
    end
  end

  describe "render_keys/2" do
    test "a template without an owner assigns no keys" do
      graph = Graph.build([], js_paths: [])
      assert Assigns.render_keys(graph, Parser.parse("<p>{@a}</p>")) == {:ok, MapSet.new()}
    end

    test "a template whose owner is not in the graph assigns no keys" do
      graph = Graph.build([], js_paths: [])
      template = Parser.parse("<p>{@a}</p>", owner: {AssignsTestLive, :render})

      assert Assigns.render_keys(graph, template) == {:ok, MapSet.new()}
    end
  end
end
