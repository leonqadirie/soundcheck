defmodule Soundcheck.Check.UnscopedLookupByClientParamTest do
  use Soundcheck.CheckCase

  import Soundcheck.HeexCase, only: [text_at: 2]

  alias Soundcheck.Check.Warning.UnscopedLookupByClientParam

  defp live(callbacks, module \\ "MyAppWeb.PostLive") do
    """
    defmodule #{module} do
      use MyAppWeb, :live_view
      alias MyApp.Repo
      import Ecto.Query

    #{callbacks}
    end
    """
  end

  test "fires on a lookup by an event param, through bindings and pipes" do
    source =
      live(~S"""
        def handle_event("delete", %{"id" => id}, socket) do
          post = Repo.get!(Post, id)
          {:ok, _} = Repo.delete(post)
          {:noreply, socket}
        end

        def handle_params(params, _uri, socket) do
          post_id = params["id"]
          query = from(p in Post, where: p.id == ^post_id)
          {:noreply, assign(socket, :post, query |> Repo.one())}
        end
      """)

    assert [get, one] = analyze(UnscopedLookupByClientParam, source)
    assert text_at(source, get.primary) == "Repo.get!"
    assert get.message =~ ~s|in `handle_event("delete", ...)` looks data up|
    assert text_at(source, one.primary) == "Repo.one"
    assert one.message =~ "`handle_params/3`"
  end

  test "near miss: scope assigns, authorizers, and untainted lookups" do
    for callbacks <- [
          ~S"""
            def handle_event("delete", %{"id" => id}, socket) do
              Repo.get_by!(Post, id: id, user_id: socket.assigns.current_user.id)
            end
          """,
          ~S"""
            def handle_event("delete", %{"id" => id}, %{assigns: %{current_scope: scope}} = socket) do
              Repo.get!(Post, id) |> check(scope)
            end
          """,
          ~S"""
            def handle_event("delete", %{"id" => id}, socket) do
              post = Repo.get!(Post, id)
              :ok = Bodyguard.permit(MyApp.Blog, :delete, socket.assigns.user, post)
            end
          """,
          ~S"""
            def handle_event("refresh", _params, socket) do
              Repo.all(Post)
            end
          """,
          ~S"""
            def handle_event("create", %{"post" => attrs}, socket) do
              Repo.insert(Post.changeset(%Post{}, attrs))
            end
          """
        ] do
      assert [] = analyze(UnscopedLookupByClientParam, live(callbacks)),
             "expected no finding for: #{callbacks}"
    end
  end

  test "near miss: a pinned variable in a pattern binds nothing" do
    source =
      live(~S"""
        def handle_event("comment", %{"id" => id}, socket) do
          user = socket.assigns.viewer
          {:ok, ^user} = Blog.fetch_post(id)
          Repo.get!(Comment, user.id)
        end
      """)

    assert [] = analyze(UnscopedLookupByClientParam, source)
  end

  test "fires on a variable a pattern rebinds next to its own pin" do
    source =
      live(~S"""
        def handle_event("comment", %{"id" => id}, socket) do
          user = socket.assigns.viewer
          {^user, user} = {user, String.to_integer(id)}
          Repo.get!(Comment, user)
        end
      """)

    assert [get] = analyze(UnscopedLookupByClientParam, source)
    assert text_at(source, get.primary) == "Repo.get!"
  end

  test "fires on get_ and fetch_ lookups in the project's own context modules" do
    context = """
    defmodule MyApp.Blog do
      def get_post!(id), do: id
      def fetch_draft(id), do: {:ok, id}
    end
    """

    source =
      live(~S"""
        alias MyApp.Blog

        def handle_event("show", %{"id" => id}, socket) do
          post = Blog.get_post!(id)
          {:ok, draft} = MyApp.Blog.fetch_draft(id)
          title = Map.get_lazy(%{"id" => id}, "title", fn -> "" end)
          {:noreply, assign(socket, post: post, draft: draft, title: title)}
        end
      """)

    diagnostics =
      analyze(UnscopedLookupByClientParam, [{"lib/blog.ex", context}, {"lib/live.ex", source}])

    assert Enum.map(diagnostics, &text_at(source, &1.primary)) == [
             "Blog.get_post!",
             "MyApp.Blog.fetch_draft"
           ]
  end

  test "near miss: context lookups in dependencies, or scoped by the clause" do
    source =
      live(~S"""
        alias MyApp.Blog

        def handle_event("show", %{"id" => id}, socket) do
          {:noreply, assign(socket, :post, Blog.get_post!(id))}
        end

        def handle_event("mine", %{"id" => id}, socket) do
          post = Blog.get_post!(socket.assigns.current_scope, id)
          {:noreply, assign(socket, :post, post)}
        end
      """)

    # MyApp.Blog is not among the analyzed sources: a dependency.
    assert [] = analyze(UnscopedLookupByClientParam, source)

    ash_domain = """
    defmodule MyApp.Blog do
      use Ash.Domain
    end
    """

    # Ash policies authorize code-interface calls.
    assert [] =
             analyze(UnscopedLookupByClientParam, [
               {"lib/blog.ex", ash_domain},
               {"lib/live.ex", source}
             ])
  end

  test "honors excluded_modules and repo_modules" do
    callbacks = ~S"""
      def handle_event("show", %{"id" => id}, socket), do: Repo.get(Post, id)
    """

    assert [] = analyze(UnscopedLookupByClientParam, live(callbacks, "MyAppWeb.Admin.PostLive"))
    assert [] = analyze(UnscopedLookupByClientParam, live(callbacks), repo_modules: [MyApp.Other])
  end
end
