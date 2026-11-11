defmodule Soundcheck.Check.AssignUseTest do
  use Soundcheck.CheckCase

  import Soundcheck.HeexCase, only: [text_at: 2]

  alias Soundcheck.Check.Design.UnreadAssign
  alias Soundcheck.Check.Refactor.StreamCandidate
  alias Soundcheck.Check.Refactor.TemporaryAssignCandidate

  defp live(callbacks, template) do
    """
    defmodule MyAppWeb.FeedLive do
      use MyAppWeb, :live_view

    #{callbacks}

      def render(assigns) do
        ~H\"\"\"
    #{template}
        \"\"\"
      end
    end
    """
  end

  @mount """
    def mount(_params, _session, socket) do
      {:ok, assign(socket, posts: [], page_size: 20)}
    end
  """

  describe "UnreadAssign (SC205)" do
    test "fires on a key nothing reads, at its first write" do
      source = live(@mount, ~S|<p :for={post <- @posts}>{post}</p>|)
      assert [diagnostic] = analyze(UnreadAssign, source)
      assert text_at(source, diagnostic.primary) == "assign"
      assert diagnostic.message =~ "assigns `:page_size` but no template"
    end

    test "near miss: reads in code, function heads, and Map.get" do
      for reader <- [
            "  def handle_event(\"more\", _, socket), do: {:noreply, socket.assigns.page_size}",
            "  def handle_event(\"more\", _, %{assigns: %{page_size: size}}), do: size",
            "  def handle_event(\"more\", _, socket), do: Map.get(socket.assigns, :page_size)",
            "  def handle_event(\"more\", _, socket), do: socket.assigns[:page_size]"
          ] do
        source = live(@mount <> reader, ~S|<p :for={post <- @posts}>{post}</p>|)
        assert [] = analyze(UnreadAssign, source), "expected no finding for: #{reader}"
      end
    end

    test "near miss: template reads through the assigns map and in EEx clause heads" do
      for template <- [
            ~S|<p :for={post <- @posts}>{assigns[:page_size]}</p>|,
            ~S|<p :for={post <- @posts}>{Map.get(assigns, :page_size)}</p>|,
            ~S"""
            <%= cond do %>
              <% @posts == [] -> %>none
              <% @page_size > 10 -> %>many
            <% end %>
            """
          ] do
        source = live(@mount, template)
        assert [] = analyze(UnreadAssign, source), "expected no finding for: #{template}"
      end
    end

    test "near miss: a helper in another module reads the key from the socket it receives" do
      helpers = """
      defmodule MyAppWeb.FeedHelpers do
        def paginate(socket, params), do: limit(socket, params["page"])
        defp limit(socket, page), do: {page, socket.assigns.page_size}
        def unrelated(socket), do: socket.assigns.other
      end
      """

      for call <- [
            "socket |> MyAppWeb.FeedHelpers.paginate(params)",
            "MyAppWeb.FeedHelpers.paginate(socket, params)"
          ] do
        callbacks =
          @mount <>
            """
              def handle_params(params, _uri, socket) do
                _ = #{call}
                {:noreply, socket}
              end
            """

        source = live(callbacks, ~S|<p :for={post <- @posts}>{post}</p>|)

        assert [] = analyze(UnreadAssign, [{"lib/live.ex", source}, {"lib/helpers.ex", helpers}]),
               "expected no finding for: #{call}"
      end

      unrelated =
        live(
          @mount <> "  def handle_info(_, socket), do: MyAppWeb.FeedHelpers.unrelated(socket)",
          ~S|<p :for={post <- @posts}>{post}</p>|
        )

      assert [%{message: message}] =
               analyze(UnreadAssign, [{"lib/live.ex", unrelated}, {"lib/helpers.ex", helpers}])

      assert message =~ "`:page_size`"
    end

    test "Keyword.update and Map.update are not assign writes" do
      callbacks =
        @mount <>
          """
            def handle_event("filter", _, socket) do
              opts = Keyword.update([], :filter, nil, & &1)
              {:noreply, assign(socket, :posts, Map.update(%{}, :sort, nil, & &1) && opts)}
            end
          """

      source = live(callbacks, ~S|<p :for={post <- @posts}>{post}</p>|)
      messages = source |> then(&analyze(UnreadAssign, &1)) |> Enum.map(& &1.message)

      assert Enum.any?(messages, &(&1 =~ "`:page_size`"))
      refute Enum.any?(messages, &(&1 =~ "`:filter`" or &1 =~ "`:sort`"))
    end

    test "near miss: layouts read the key, or the assigns map escapes whole" do
      layouts = """
      defmodule MyAppWeb.Layouts do
        use Phoenix.Component
        def app(assigns), do: ~H"<main>{@page_size}</main>"
      end
      """

      source = live(@mount, ~S|<p :for={post <- @posts}>{post}</p>|)
      assert [] = analyze(UnreadAssign, [{"lib/live.ex", source}, {"lib/layouts.ex", layouts}])

      escaping = live(@mount, ~S|<.list posts={@posts} {assigns} />|)
      assert [] = analyze(UnreadAssign, escaping)

      helper =
        live(@mount <> "  def handle_info(_, socket), do: helper(socket.assigns)", "{@posts}")

      assert [] = analyze(UnreadAssign, helper)
    end

    test "a spread into a layout component reads only what the layout reads" do
      layouts = """
      defmodule MyAppWeb.Layouts do
        use Phoenix.Component
        def app(assigns), do: ~H"<main>{@posts}</main>"
      end
      """

      source = live(@mount, ~S|<Layouts.app {assigns}>hi</Layouts.app>|)

      assert [%{message: message}] =
               analyze(UnreadAssign, [{"lib/live.ex", source}, {"lib/layouts.ex", layouts}])

      assert message =~ ":page_size"
    end

    test "honors ignore_assigns" do
      source = live(@mount, ~S|<p :for={post <- @posts}>{post}</p>|)
      assert [] = analyze(UnreadAssign, source, ignore_assigns: [:page_size])
    end
  end

  describe "StreamCandidate (SC307)" do
    @loop ~S|<p :for={message <- @messages}>{message}</p>|

    test "fires on update with append or prepend functions" do
      for writer <- [
            "update(socket, :messages, &(&1 ++ [message]))",
            "update(socket, :messages, &[message | &1])",
            "update(socket, :messages, fn messages -> messages ++ [message] end)",
            "socket |> update(:messages, &(&1 ++ [message]))",
            "assign(socket, :messages, socket.assigns.messages ++ [message])"
          ] do
        source =
          live("  def handle_info({:new, message}, socket), do: {:noreply, #{writer}}", @loop)

        assert [diagnostic] = analyze(StreamCandidate, source),
               "expected a finding for: #{writer}"

        assert diagnostic.message =~ "`:messages` grows one item at a time"
      end
    end

    test "near miss: full replacement, or no :for over the key" do
      replace =
        live(
          "  def handle_info(:reload, socket), do: {:noreply, assign(socket, :messages, list())}",
          @loop
        )

      assert [] = analyze(StreamCandidate, replace)

      unlooped =
        live(
          "  def handle_info({:new, m}, socket), do: {:noreply, update(socket, :messages, &(&1 ++ [m]))}",
          "{length(@messages)}"
        )

      assert [] = analyze(StreamCandidate, unlooped)
    end
  end

  describe "TemporaryAssignCandidate (SC308)" do
    @lines ~S|<p :for={line <- @log_lines}>{line}</p>|
    @refresh "  def handle_event(\"refresh\", _, socket), do: {:noreply, assign(socket, :log_lines, fetch())}"

    test "fires on a key replaced whole and rendered once in :for" do
      source = live(@refresh, @lines)
      assert [diagnostic] = analyze(TemporaryAssignCandidate, source)
      assert text_at(source, diagnostic.primary) == "assign"
    end

    test "near miss: read in code, read twice, updated, or already temporary" do
      for {callbacks, template} <- [
            {@refresh <> "\n  def handle_event(\"count\", _, s), do: length(s.assigns.log_lines)",
             @lines},
            {@refresh, @lines <> "{length(@log_lines)}"},
            {@refresh <> "\n  def handle_info(l, s), do: update(s, :log_lines, &[l | &1])",
             @lines},
            {"  def mount(_, _, s), do: {:ok, assign(s, :log_lines, []), temporary_assigns: [log_lines: []]}",
             @lines}
          ] do
        source = live(callbacks, template)

        assert [] = analyze(TemporaryAssignCandidate, source),
               "expected no finding for: #{callbacks}"
      end
    end
  end
end
