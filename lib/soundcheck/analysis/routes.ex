defmodule Soundcheck.Analysis.Routes do
  @moduledoc false
  # Matches paths written in source (`"/posts"`, `~p"/posts/#{post}/edit"`)
  # against the project's live routes.
  #
  # Inside `~p`, an interpolation is one path segment: `~p` escapes slashes
  # in the values it interpolates, so `~p"/posts/#{post}"` matches only
  # two-segment routes. In a plain string the interpolated value can hold
  # slashes (`"#{base_path}/edit"`), so a segment with an interpolation
  # matches any number of route segments, none included. Either way a path
  # can match several routes. The query string is ignored.

  @type segment :: String.t() | :dynamic | :any

  @doc """
  Turns a path literal, an interpolated string, or a `~p` sigil AST into
  segments, or `:error` when the path is not written in place.
  """
  @spec segments(Macro.t()) :: {:ok, [segment()]} | :error
  def segments(path) when is_binary(path), do: {:ok, split(path)}

  def segments({:sigil_p, _, [{:<<>>, _, parts}, _modifiers]}),
    do: {:ok, interpolated(parts, :dynamic)}

  def segments({:<<>>, _, parts}), do: {:ok, interpolated(parts, :any)}

  def segments(_expression), do: :error

  defmodule Index do
    @moduledoc false
    # Live routes as a trie over their path segments. A node holds the
    # routes that end there (`ends`), the routes whose next segment is a
    # glob (`globs`), one child per literal next segment (`literals`), and
    # one child for every parameter next segment (`param`). A route is its
    # position among the indexed routes and the route itself.
    #
    # Matching a path walks only the children its segments allow, so the
    # work follows the routes that share the path's prefix, not every
    # route. Routes under one scope (`/admin/...`) or behind a leading
    # parameter (`/:locale/...`) share their first segment, so an index on
    # that segment alone would not narrow them.
    defstruct ends: [], globs: [], literals: %{}, param: nil

    @type route :: {position :: non_neg_integer(), route :: map()}
    @type t :: %__MODULE__{
            ends: [route()],
            globs: [route()],
            literals: %{String.t() => t()},
            param: t() | nil
          }
  end

  @doc """
  Indexes `routes` for `matching/2`. A check matches every navigation
  against the routes, so it builds the index once.
  """
  @spec index([map()]) :: Index.t()
  def index(routes) do
    {index, _count} =
      Enum.reduce(routes, {%Index{}, 0}, fn route, {index, position} ->
        segments = String.split(route.path, "/", trim: true)
        {insert(index, segments, {position, route}), position + 1}
      end)

    index
  end

  defp insert(%Index{} = node, [], route), do: %{node | ends: [route | node.ends]}

  defp insert(%Index{} = node, ["*" <> _glob | _rest], route),
    do: %{node | globs: [route | node.globs]}

  defp insert(%Index{} = node, [":" <> _param | rest], route),
    do: %{node | param: insert(node.param || %Index{}, rest, route)}

  defp insert(%Index{} = node, [literal | rest], route) do
    child = Map.get(node.literals, literal, %Index{})
    %{node | literals: Map.put(node.literals, literal, insert(child, rest, route))}
  end

  @doc "The routes of `index` whose path can match `segments`, in route order."
  @spec matching(Index.t(), [segment()]) :: [map()]
  def matching(%Index{} = index, segments) do
    # A path with `:any` reaches a route along several walks; the map keeps
    # each route once, and sorting it by position restores route order.
    index
    |> collect(segments, %{})
    |> Enum.sort()
    |> Enum.map(fn {_position, route} -> route end)
  end

  defp collect(nil, _segments, found), do: found

  # A glob matches whatever is left of the path, nothing included.
  defp collect(%Index{globs: globs} = node, segments, found),
    do: walk(node, segments, Enum.into(globs, found))

  defp walk(node, [], found), do: Enum.into(node.ends, found)

  # `:any` consumes no route segments, or one and stays in place for more.
  defp walk(node, [:any | rest] = segments, found) do
    found = walk(node, rest, found)
    Enum.reduce(children(node), found, &collect(&1, segments, &2))
  end

  defp walk(node, [:dynamic | rest], found),
    do: Enum.reduce(children(node), found, &collect(&1, rest, &2))

  defp walk(node, [literal | rest], found) do
    found = collect(Map.get(node.literals, literal), rest, found)
    collect(node.param, rest, found)
  end

  defp children(%Index{literals: literals, param: param}), do: [param | Map.values(literals)]

  # Marks each interpolation with a NUL byte, then turns every segment that
  # holds one into `dynamic`.
  defp interpolated(parts, dynamic) do
    parts
    |> Enum.map_join(fn part -> if is_binary(part), do: part, else: <<0>> end)
    |> split()
    |> Enum.map(&if(is_binary(&1) and String.contains?(&1, <<0>>), do: dynamic, else: &1))
  end

  defp split(path) do
    path
    |> String.split("?", parts: 2)
    |> hd()
    |> String.split("/", trim: true)
  end
end
