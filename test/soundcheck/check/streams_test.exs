defmodule Soundcheck.Check.StreamsTest do
  use Soundcheck.CheckCase

  import Soundcheck.HeexCase, only: [text_at: 2]

  alias Soundcheck.Check.Warning.StreamChildWithoutId
  alias Soundcheck.Check.Warning.StreamConsumedOutsideFor
  alias Soundcheck.Check.Warning.StreamContainerWithoutPhxUpdate

  defp live(template) do
    """
    defmodule MyAppWeb.PostLive do
      use MyAppWeb, :live_view

      def render(assigns) do
        ~H\"\"\"
    #{template}
        \"\"\"
      end
    end
    """
  end

  describe "StreamContainerWithoutPhxUpdate (SC304)" do
    test "fires on a stream loop whose parent lacks phx-update" do
      source =
        live(
          ~S|    <ul id="posts"><li :for={{id, p} <- @streams.posts} id={id}>{p.title}</li></ul>|
        )

      assert [diagnostic] = analyze(StreamContainerWithoutPhxUpdate, source)
      assert text_at(source, diagnostic.primary) == ~S|<ul id="posts">|
    end

    test "near miss: the parent has phx-update=\"stream\"" do
      source =
        live(
          ~S|    <ul id="posts" phx-update="stream"><li :for={{id, p} <- @streams.posts} id={id}></li></ul>|
        )

      assert [] = analyze(StreamContainerWithoutPhxUpdate, source)
    end

    test "skips loops under components and at the template root" do
      source = live(~S|    <.list><li :for={{id, p} <- @streams.posts} id={id}></li></.list>|)
      assert [] = analyze(StreamContainerWithoutPhxUpdate, source)
    end
  end

  describe "StreamChildWithoutId (SC305)" do
    test "fires on a child without an id and on a literal id" do
      source =
        live("""
            <ul id="a" phx-update="stream"><li :for={{_id, p} <- @streams.posts}>{p.title}</li></ul>
            <ul id="b" phx-update="stream"><li :for={{_id, p} <- @streams.drafts} id="row">{p.title}</li></ul>
        """)

      assert [missing, literal] = analyze(StreamChildWithoutId, source)
      assert missing.message =~ "has no `id`"
      assert literal.message =~ "literal id `row`"
    end

    test "near miss: id from the stream, and component children" do
      source =
        live(
          ~S|    <ul id="a" phx-update="stream"><li :for={{id, p} <- @streams.posts} id={id}></li><.row :for={{id, r} <- @streams.rows} /></ul>|
        )

      assert [] = analyze(StreamChildWithoutId, source)
    end

    test "near miss: a static empty-state child with a literal id" do
      source =
        live(
          ~S|    <ul id="a" phx-update="stream"><li id="a-empty" class="only:block hidden">None</li><li :for={{id, p} <- @streams.posts} id={id}></li></ul>|
        )

      assert [] = analyze(StreamChildWithoutId, source)
    end
  end

  describe "StreamConsumedOutsideFor (SC306)" do
    test "fires on a stream used outside a comprehension" do
      source =
        live(~S|    <p>{length(@streams.posts)} posts</p><p>{Enum.count(@streams[:drafts])}</p>|)

      assert [posts, drafts] = analyze(StreamConsumedOutsideFor, source)
      assert text_at(source, posts.primary) == "@streams.posts"
      assert drafts.message =~ "@streams.drafts"
    end

    test "near miss: a stream passed to a component attribute" do
      source =
        live(
          ~S|    <.table id="posts" rows={@streams.posts}><:col :let={{_id, p}}>{p.title}</:col></.table>|
        )

      assert [] = analyze(StreamConsumedOutsideFor, source)
    end

    test "near miss: :for and EEx comprehensions" do
      source =
        live("""
            <ul id="a" phx-update="stream"><li :for={{id, p} <- @streams.posts} id={id}></li></ul>
            <%= for {id, c} <- @streams.comments do %><p id={id}>{c.body}</p><% end %>
        """)

      assert [] = analyze(StreamConsumedOutsideFor, source)
    end
  end
end
