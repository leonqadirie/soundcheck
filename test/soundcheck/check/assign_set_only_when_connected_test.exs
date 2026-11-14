defmodule Soundcheck.Check.Warning.AssignSetOnlyWhenConnectedTest do
  use Soundcheck.CheckCase

  import Soundcheck.HeexCase, only: [text_at: 2]

  alias Soundcheck.Analysis.Assigns
  alias Soundcheck.Check.Warning.AssignSetOnlyWhenConnected

  @fixture "test/support/fixtures/connected.ex"

  defp fixture, do: [{@fixture, File.read!(@fixture)}]

  test "fires on a key mount assigns only when connected" do
    assert [diagnostic] = analyze(AssignSetOnlyWhenConnected, fixture())

    assert diagnostic.resolution == :resolved
    assert diagnostic.message =~ "`@stats` is read in `render/1`"
    assert text_at(File.read!(@fixture), diagnostic.primary) == "@stats"
  end

  test "near miss: a disconnected mount that always redirects never renders" do
    file = "test/support/fixtures/navigating.ex"
    assert [] = analyze(AssignSetOnlyWhenConnected, [{file, File.read!(file)}])
  end

  test "near misses: assigned in both branches, by handle_params, or after an open call" do
    messages =
      fixture() |> then(&analyze(AssignSetOnlyWhenConnected, &1)) |> Enum.map(& &1.message)

    refute Enum.any?(messages, &(&1 =~ "@chart"))
    refute Enum.any?(messages, &(&1 =~ "@title"))
    assert [_only_connected_live] = messages
  end

  describe "the interpreter" do
    defp mount(source) do
      {:ok, ast} = Code.string_to_quoted(source)
      {:def, _, [{:mount, _, args}, [do: body]]} = ast
      [%{args: args, body: body}]
    end

    test "follows connected? branches, negations, and renamed sockets" do
      clauses =
        mount("""
        def mount(_p, _s, socket) do
          next = assign(socket, :a, 1)
          next = if !connected?(next), do: assign(next, :b, 2), else: assign(next, c: 3)
          {:ok, stream(next, :items, [])}
        end
        """)

      assert Assigns.mount(clauses, false).may == MapSet.new([:a, :b, :streams])
      assert Assigns.mount(clauses, true).may == MapSet.new([:a, :c, :streams])
      refute Assigns.mount(clauses, false).open?
    end

    test "a compound connected? condition picks the branch only in the run it decides" do
      clauses =
        mount("""
        def mount(_p, _s, socket) do
          socket =
            if connected?(socket) and enabled?(),
              do: assign(socket, :a, 1),
              else: assign(socket, :b, 2)

          {:ok, socket}
        end
        """)

      disconnected = Assigns.mount(clauses, false)
      assert disconnected.may == MapSet.new([:b])
      assert disconnected.must == MapSet.new([:b])

      connected = Assigns.mount(clauses, true)
      assert connected.may == MapSet.new([:a, :b])
      assert connected.must == MapSet.new()
    end

    test "the disconnected run skips a helper behind `connected?(socket) and`" do
      clauses =
        mount("""
        def mount(_p, _s, socket) do
          if connected?(socket) and load(socket), do: :ok
          {:ok, socket}
        end
        """)

      refute Assigns.mount(clauses, false).open?
      assert Assigns.mount(clauses, true).open?
    end

    test "a helper receiving the socket opens the context" do
      clauses = mount("def mount(_p, _s, socket), do: {:ok, load(socket)}")
      assert Assigns.mount(clauses, false).open?
    end

    test "an Enum closure that receives the socket may assign its keys" do
      clauses =
        mount("""
        def mount(_p, _s, socket) do
          socket =
            if connected?(socket),
              do: assign(socket, :x, 0),
              else: Enum.reduce([1], socket, fn i, acc -> assign(acc, :x, i) end)

          {:ok, socket}
        end
        """)

      disconnected = Assigns.mount(clauses, false)
      assert disconnected.may == MapSet.new([:x])
      assert disconnected.must == MapSet.new()
      refute disconnected.open?
    end

    test "a then/2 closure assigns its keys on every path" do
      clauses =
        mount("def mount(_p, _s, socket), do: {:ok, then(socket, fn s -> assign(s, :x, 1) end)}")

      assert Assigns.mount(clauses, false).must == MapSet.new([:x])
    end

    test "a helper receiving a closure's socket parameter opens the context" do
      clauses =
        mount("""
        def mount(_p, _s, socket),
          do: {:ok, Enum.reduce([1], socket, fn _i, acc -> load(acc) end)}
        """)

      assert Assigns.mount(clauses, false).open?
    end
  end
end
