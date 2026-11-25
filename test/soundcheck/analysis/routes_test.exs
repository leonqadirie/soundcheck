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

  describe "matching/2 against a route-by-route reference" do
    # The matching rules, one route at a time. The index must return the
    # same routes for every path, in route order.
    defp reference(["*" <> _glob | _rest], _segments), do: true

    defp reference(route, [:any | segments] = any),
      do: reference(route, segments) or (route != [] and reference(tl(route), any))

    defp reference([], []), do: true
    defp reference([], _segments), do: false
    defp reference(_route, []), do: false
    defp reference([":" <> _param | route], [_segment | segments]), do: reference(route, segments)
    defp reference([_literal | route], [:dynamic | segments]), do: reference(route, segments)
    defp reference([literal | route], [literal | segments]), do: reference(route, segments)
    defp reference(_route, _segments), do: false

    defp sequences(_alphabet, 0), do: [[]]

    defp sequences(alphabet, length) do
      shorter = sequences(alphabet, length - 1)

      shorter ++
        for(first <- alphabet, rest <- shorter, length(rest) == length - 1, do: [first | rest])
    end

    test "every path up to three segments matches the same routes" do
      route_segments =
        for prefix <- sequences(["a", "b", ":id", ":slug"], 3),
            route <- [prefix, prefix ++ ["*rest"]],
            do: route

      routes = for segments <- route_segments, do: %{path: "/" <> Enum.join(segments, "/")}
      index = Routes.index(routes)

      for path <- sequences(["a", "b", "c", :dynamic, :any], 3) do
        expected =
          for {route, segments} <- Enum.zip(routes, route_segments),
              reference(segments, path),
              do: route

        assert Routes.matching(index, path) == expected,
               "path #{inspect(path)} matches other routes than the reference"
      end
    end
  end
end
