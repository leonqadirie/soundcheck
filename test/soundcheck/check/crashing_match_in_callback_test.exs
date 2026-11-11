defmodule Soundcheck.Check.CrashingMatchInCallbackTest do
  use Soundcheck.CheckCase

  import Soundcheck.HeexCase, only: [text_at: 2]

  alias Soundcheck.Check.Warning.CrashingMatchInCallback

  defp live(body) do
    """
    defmodule MyAppWeb.PostLive do
      use MyAppWeb, :live_view
      alias MyApp.Blog

    #{body}
    end
    """
  end

  test "fires on tagged-tuple matches on calls and pipes in callbacks" do
    source =
      live("""
        def handle_event("save", %{"post" => params}, socket) do
          {:ok, post} = Blog.update_post(socket.assigns.post, params)
          {:ok, _, _} = params |> normalize() |> MyApp.Blog.store()
          {:noreply, assign(socket, :post, post)}
        end

        def mount(_params, _session, socket) do
          {:ok, user} = fetch_user(socket)
          {:ok, assign(socket, :user, user)}
        end
      """)

    assert [update, store, mount] = analyze(CrashingMatchInCallback, source)
    assert text_at(source, mount.primary) == "fetch_user"
    assert text_at(source, update.primary) == "Blog.update_post"
    assert text_at(source, store.primary) == "MyApp.Blog.store"
    assert update.message =~ "`{:ok, ...} = Blog.update_post(...)` in `handle_event/3`"
  end

  test "near miss: case, with, closures, untagged patterns, values, and other functions" do
    source =
      live("""
        def handle_event("save", params, socket) do
          case Blog.update_post(params) do
            {:ok, post} -> {:noreply, assign(socket, :post, post)}
            {:error, _} -> {:noreply, socket}
          end
        end

        def handle_info(:tick, socket) do
          with {:ok, post} <- Blog.fetch(socket.assigns.id) do
            {left, right} = Enum.split(post.tags, 2)
            {:ok, cached} = socket.assigns.cache
            {:ok, literal} = {:ok, left ++ right}
            start_async(socket, :load, fn -> {:ok, data} = Blog.load(); data end)
            {:noreply, assign(socket, cached: cached, literal: literal)}
          end
        end

        def helper(params) do
          {:ok, post} = Blog.update_post(params)
          post
        end
      """)

    assert [] = analyze(CrashingMatchInCallback, source)
  end
end
