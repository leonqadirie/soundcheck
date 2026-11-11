defmodule Soundcheck.Check.UndefinedStreamTest do
  use Soundcheck.CheckCase

  import Soundcheck.HeexCase, only: [text_at: 2]

  alias Soundcheck.Check.Warning.UndefinedStream

  @fixture "test/support/fixtures/stream_names.ex"

  defp fixture, do: [{@fixture, File.read!(@fixture)}]

  test "fires on template reads and stream calls of names the module never defines" do
    diagnostics = analyze(UndefinedStream, fixture())
    texts = Enum.map(diagnostics, &text_at(File.read!(@fixture), &1.primary))

    assert texts == ["@streams.post", "stream_delete"]

    assert Enum.all?(
             diagnostics,
             &(&1.message =~ "uses the stream :post but defines only :comments, :posts")
           )

    assert Enum.all?(diagnostics, &(&1.suggestion == "Did you mean :posts?"))
  end

  test "near miss: configured streams, helper-defined streams, and dynamic names" do
    diagnostics = analyze(UndefinedStream, fixture())

    refute Enum.any?(
             diagnostics,
             &(&1.message =~ ~r/HelperStreamsLive|DynamicStreamsLive|:comments but/)
           )
  end

  describe "helper-defined streams" do
    @board """
    defmodule Demo.Board do
      import Phoenix.LiveView, only: [stream: 4]

      def assign_board(socket, tasks), do: socket |> stream(:board_lanes, lanes(tasks), reset: true)

      defp lanes(tasks), do: tasks
    end
    """

    defp live(body) do
      """
      defmodule Demo.ShowLive do
        use Phoenix.LiveView
        alias Demo.Board

      #{body}

        def render(assigns) do
          ~H\"\"\"
          <div :for={{id, task} <- @streams.tasks} id={id}>{task}</div>
          <div :for={{id, lane} <- @streams.board_lanes} id={id}>{lane}</div>
          \"\"\"
        end
      end
      """
    end

    test "near miss: a module streams some names and a helper module's pipe streams the rest" do
      source =
        live("""
          def mount(_params, _session, socket) do
            {:ok, socket |> stream(:tasks, []) |> load()}
          end

          defp load(socket), do: socket |> Board.assign_board([])
        """)

      assert analyze(UndefinedStream, [{"lib/board.ex", @board}, {"lib/show.ex", source}]) == []
    end

    test "near miss: an imported helper streams the name" do
      source =
        live("""
          import Demo.Board

          def mount(_params, _session, socket),
            do: {:ok, socket |> stream(:tasks, []) |> assign_board([])}
        """)

      assert analyze(UndefinedStream, [{"lib/board.ex", @board}, {"lib/show.ex", source}]) == []
    end

    test "fires on a typo when helpers define the other streams" do
      source =
        String.replace(
          live("""
            def mount(_params, _session, socket),
              do: {:ok, socket |> stream(:tasks, []) |> Board.assign_board([])}
          """),
          "@streams.board_lanes",
          "@streams.board_lane"
        )

      assert [diagnostic] =
               analyze(UndefinedStream, [{"lib/board.ex", @board}, {"lib/show.ex", source}])

      assert diagnostic.message =~
               "uses the stream :board_lane but defines only :board_lanes, :tasks"

      assert diagnostic.suggestion == "Did you mean :board_lanes?"
    end

    test "near miss: helpers that call each other in a cycle" do
      helpers = """
      defmodule Demo.Ping do
        def ping(socket, 0), do: Phoenix.LiveView.stream(socket, :board_lanes, [])
        def ping(socket, n), do: Demo.Pong.pong(socket, n - 1)
      end

      defmodule Demo.Pong do
        def pong(socket, n), do: Demo.Ping.ping(socket, n)
      end
      """

      source =
        live("""
          def mount(_params, _session, socket),
            do: {:ok, socket |> stream(:tasks, []) |> Demo.Ping.ping(3)}
        """)

      assert analyze(UndefinedStream, [{"lib/helpers.ex", helpers}, {"lib/show.ex", source}]) ==
               []
    end

    test "near miss: the socket goes to a function outside the project" do
      source =
        live("""
          def mount(_params, _session, socket),
            do: {:ok, socket |> stream(:tasks, []) |> External.Lanes.assign(:board)}
        """)

      assert analyze(UndefinedStream, [{"lib/show.ex", source}]) == []
    end

    test "fires when calls outside the project do not take the socket" do
      source =
        live("""
          def mount(_params, _session, socket),
            do: {:ok, stream(socket, :tasks, External.Tasks.list())}
        """)

      assert [diagnostic] = analyze(UndefinedStream, [{"lib/show.ex", source}])
      assert diagnostic.message =~ "uses the stream :board_lanes but defines only :tasks"
    end
  end
end
