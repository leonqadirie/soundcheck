defmodule Soundcheck.Analysis.RoutesTest do
  use ExUnit.Case, async: true

  alias Soundcheck.Analysis.Routes

  @routes [
    %{path: "/"},
    %{path: "/posts"},
    %{path: "/:locale/posts"},
    %{path: "/posts/:id"},
    %{path: "/posts/:id/edit"},
    %{path: "/users/:id"},
    %{path: "/*rest"}
  ]

  defp paths(path) do
    {:ok, segments} = Routes.segments(path)
    @routes |> Routes.index() |> Routes.matching(segments) |> Enum.map(& &1.path)
  end

  defp sigil_p(parts), do: {:sigil_p, [], [{:<<>>, [], parts}, []]}
  defp interpolation, do: {:"::", [], [{:id, [], nil}, {:binary, [], nil}]}

  describe "matching/2" do
    test "a literal path matches the routes with its first segment, and the open ones" do
      assert paths("/posts") == ["/posts", "/*rest"]
    end

    test "matches come back in route order" do
      assert paths("/posts/posts") == ["/:locale/posts", "/posts/:id", "/*rest"]
    end

    test "a route that starts with a parameter matches any first segment" do
      assert paths("/en/posts") == ["/:locale/posts", "/*rest"]
    end

    test "near miss: a route with another first segment does not match" do
      assert paths("/users/7") == ["/users/:id", "/*rest"]
    end

    test "the root path matches the root route and a glob" do
      assert paths("/") == ["/", "/*rest"]
    end

    test "the query string does not count" do
      assert paths("/posts?page=2") == ["/posts", "/*rest"]
    end

    test "a path that starts with a ~p interpolation matches every first segment" do
      assert paths(sigil_p([interpolation(), "/posts"])) ==
               ["/:locale/posts", "/posts/:id", "/users/:id", "/*rest"]
    end

    test "a ~p interpolation after a literal is one segment" do
      assert paths(sigil_p(["/posts/", interpolation(), "/edit"])) ==
               ["/posts/:id/edit", "/*rest"]
    end

    test "a string interpolation matches any number of segments" do
      assert paths({:<<>>, [], [interpolation(), "/edit"]}) ==
               ["/posts/:id", "/posts/:id/edit", "/users/:id", "/*rest"]
    end
  end
end
