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
    # Live routes with their paths split once. `open` holds the routes whose
    # first segment is a parameter or a glob, which a path can match
    # whatever its first segment is. `by_first` maps a literal first segment
    # to the routes that start with it plus the open ones: every route a
    # path starting with that literal can match. The root route has no
    # first segment and appears only in `rows`. Every list is in route
    # order, so matches come back in route order.
    @enforce_keys [:rows, :by_first, :open]
    defstruct [:rows, :by_first, :open]

    @type row :: {position :: non_neg_integer(), route :: map(), segments :: [String.t()]}
    @type t :: %__MODULE__{rows: [row()], by_first: %{String.t() => [row()]}, open: [row()]}
  end

  @doc """
  Indexes `routes` for `matching/2`. A check matches every navigation
  against the routes, so it builds the index once.
  """
  @spec index([map()]) :: Index.t()
  def index(routes) do
    rows =
      for {route, position} <- Enum.with_index(routes),
          do: {position, route, String.split(route.path, "/", trim: true)}

    {open, literal} =
      Enum.split_with(rows, fn {_position, _route, segments} -> open?(segments) end)

    # Rows sort by their position, so merging two lists in route order
    # yields a list in route order.
    by_first =
      for({_position, _route, [first | _rest]} = row <- literal, do: {first, row})
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Map.new(fn {first, group} -> {first, :lists.merge(group, open)} end)

    %Index{rows: rows, open: open, by_first: by_first}
  end

  defp open?([":" <> _param | _rest]), do: true
  defp open?(["*" <> _glob | _rest]), do: true
  defp open?(_segments), do: false

  @doc "The routes of `index` whose path can match `segments`, in route order."
  @spec matching(Index.t(), [segment()]) :: [map()]
  def matching(%Index{} = index, segments) do
    for {_position, route, route_segments} <- candidates(index, segments),
        matches?(route_segments, segments),
        do: route
  end

  # A path that starts with a literal matches only the routes that start
  # with the same literal, and the open ones.
  defp candidates(%Index{by_first: by_first, open: open}, [first | _rest]) when is_binary(first),
    do: Map.get(by_first, first, open)

  defp candidates(%Index{rows: rows}, _segments), do: rows

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

  defp matches?(["*" <> _glob | _rest], _segments), do: true

  # `:any` consumes no route segments, or one and stays in place for more.
  defp matches?(route, [:any | segments] = any),
    do: matches?(route, segments) or (route != [] and matches?(tl(route), any))

  defp matches?([], []), do: true
  defp matches?([], _segments), do: false
  defp matches?(_route, []), do: false

  defp matches?([":" <> _param | route], [_segment | segments]), do: matches?(route, segments)
  defp matches?([_literal | route], [:dynamic | segments]), do: matches?(route, segments)
  defp matches?([literal | route], [literal | segments]), do: matches?(route, segments)
  defp matches?(_route, _segments), do: false
end
