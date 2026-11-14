defmodule Soundcheck.Check.BlockingWorkTest do
  use Soundcheck.CheckCase

  import Soundcheck.HeexCase, only: [text_at: 2]

  alias Soundcheck.Check.Refactor.ExpensiveMountWork
  alias Soundcheck.Check.Warning.BlockingCallInHandler

  defp mount(body) do
    """
    defmodule MyAppWeb.PostsLive do
      use MyAppWeb, :live_view
      alias MyApp.Repo

      def mount(_params, _session, socket) do
    #{body}
      end
    end
    """
  end

  defp handler(body) do
    """
    defmodule MyAppWeb.PricesLive do
      use MyAppWeb, :live_view

      def handle_event("refresh", _params, socket) do
    #{body}
      end
    end
    """
  end

  describe "SC502 ExpensiveMountWork" do
    test "fires on a Repo call in mount, through aliases" do
      source = mount("    {:ok, assign(socket, :posts, Repo.all(Post))}")
      assert [diagnostic] = analyze(ExpensiveMountWork, source)
      assert text_at(source, diagnostic.primary) == "Repo.all"
      assert diagnostic.message =~ "both the disconnected and the connected mount"
    end

    test "fires on HTTP calls" do
      assert [_diagnostic] =
               analyze(ExpensiveMountWork, mount("    Req.get!(\"/x\")\n    {:ok, socket}"))
    end

    test "near miss: closures and connected? branches" do
      for body <- [
            "    {:ok, assign_async(socket, :posts, fn -> {:ok, %{posts: Repo.all(Post)}} end)}",
            "    if connected?(socket), do: Repo.all(Post)\n    {:ok, socket}",
            "    {:ok, assign(socket, :count, Enum.count([]))}"
          ] do
        assert [] = analyze(ExpensiveMountWork, mount(body)), "expected no finding for: #{body}"
      end
    end

    test "a compound connected? condition skips what only the connected mount runs" do
      for body <- [
            "    if connected?(socket) and enabled?(), do: Repo.all(Post)\n    {:ok, socket}",
            "    if connected?(socket) and Repo.exists?(Post), do: :ok\n    {:ok, socket}"
          ] do
        assert [] = analyze(ExpensiveMountWork, mount(body)), "expected no finding for: #{body}"
      end

      source =
        mount("    if Repo.exists?(Post) and connected?(socket), do: :ok\n    {:ok, socket}")

      assert [diagnostic] = analyze(ExpensiveMountWork, source)
      assert text_at(source, diagnostic.primary) == "Repo.exists?"
    end

    test "honors expensive_modules" do
      source = mount("    MyApp.Search.run()\n    {:ok, socket}")
      assert [] = analyze(ExpensiveMountWork, source)

      assert [_diagnostic] =
               analyze(ExpensiveMountWork, source, expensive_modules: [MyApp.Search])
    end
  end

  describe "SC602 BlockingCallInHandler" do
    test "fires on sleeps, awaits, and HTTP calls" do
      source =
        handler("""
            Process.sleep(100)
            :timer.sleep(100)
            Task.await(Task.async(fn -> :ok end))
            Req.get!("/prices")
            {:noreply, socket}
        """)

      assert diagnostics = analyze(BlockingCallInHandler, source)

      assert Enum.map(diagnostics, &text_at(source, &1.primary)) ==
               ["Process.sleep", ":timer.sleep", "Task.await", "Req.get!"]

      assert hd(diagnostics).message =~ "blocks `handle_event/3`"
    end

    test "fires on blocking calls in closures that run inline" do
      source =
        handler("""
            Enum.each([1, 2], fn id -> Req.get!("/prices/\#{id}") end)
            {:noreply, then(socket, fn s -> Process.sleep(10) && s end)}
        """)

      assert diagnostics = analyze(BlockingCallInHandler, source)
      assert Enum.map(diagnostics, &text_at(source, &1.primary)) == ["Req.get!", "Process.sleep"]
    end

    test "fires on receive without after" do
      source = handler("    receive do\n      :done -> {:noreply, socket}\n    end")
      assert [diagnostic] = analyze(BlockingCallInHandler, source)
      assert text_at(source, diagnostic.primary) == "receive"
    end

    test "near miss: closures, bounded receive, and other callbacks" do
      for body <- [
            "    {:noreply, start_async(socket, :prices, fn -> Req.get!(\"/prices\") end)}",
            "    receive do\n      :done -> :ok\n    after\n      0 -> :ok\n    end\n    {:noreply, socket}"
          ] do
        assert [] = analyze(BlockingCallInHandler, handler(body)),
               "expected no finding for: #{body}"
      end

      source = """
      defmodule MyAppWeb.PricesLive do
        use MyAppWeb, :live_view
        def render_prices, do: Process.sleep(1)
      end
      """

      assert [] = analyze(BlockingCallInHandler, source)
    end

    test "honors blocking_functions" do
      source = handler("    MyApp.Sync.wait()\n    {:noreply, socket}")
      assert [] = analyze(BlockingCallInHandler, source)

      assert [_diagnostic] =
               analyze(BlockingCallInHandler, source, blocking_functions: [{MyApp.Sync, :wait}])
    end
  end
end
