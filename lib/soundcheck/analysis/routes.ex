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

  @doc "The routes whose path can match `segments`."
  @spec matching([map()], [segment()]) :: [map()]
  def matching(routes, segments),
    do: Enum.filter(routes, &matches?(route_segments(&1.path), segments))

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

  defp route_segments(path), do: String.split(path, "/", trim: true)

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
