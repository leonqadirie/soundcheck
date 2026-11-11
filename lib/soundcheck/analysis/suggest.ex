defmodule Soundcheck.Analysis.Suggest do
  @moduledoc false
  # Suggests the closest known name for a misspelled one.
  #
  # Distance is Damerau-Levenshtein (insertions, deletions, substitutions,
  # and adjacent transpositions). A candidate qualifies within
  # `max(1, div(String.length(name), 4))` edits; ties go to the higher
  # `String.jaro_distance/2`.

  @spec closest(String.t(), [String.t()]) :: String.t() | nil
  def closest(name, candidates) do
    limit = max(1, div(String.length(name), 4))

    candidates
    |> Enum.uniq()
    |> Enum.reject(&(&1 == name))
    |> Enum.map(&{&1, distance(name, &1)})
    |> Enum.filter(fn {_candidate, distance} -> distance <= limit end)
    |> Enum.sort_by(fn {candidate, distance} ->
      {distance, -String.jaro_distance(name, candidate)}
    end)
    |> case do
      [{best, _distance} | _] -> best
      [] -> nil
    end
  end

  @doc "Damerau-Levenshtein distance between two strings, over graphemes."
  @spec distance(String.t(), String.t()) :: non_neg_integer()
  def distance(a, b) do
    a = a |> String.graphemes() |> List.to_tuple()
    b = b |> String.graphemes() |> List.to_tuple()
    rows = tuple_size(a)
    cols = tuple_size(b)

    initial = for i <- 0..rows, j <- 0..cols, into: %{}, do: {{i, j}, initial_cell(i, j)}
    cells = for i <- 1..rows//1, j <- 1..cols//1, do: {i, j}

    table =
      Enum.reduce(cells, initial, fn {i, j}, table ->
        Map.put(table, {i, j}, cell(table, a, b, i, j))
      end)

    Map.fetch!(table, {rows, cols})
  end

  defp initial_cell(i, 0), do: i
  defp initial_cell(0, j), do: j
  defp initial_cell(_i, _j), do: 0

  defp cell(table, a, b, i, j) do
    cost = if elem(a, i - 1) == elem(b, j - 1), do: 0, else: 1

    best =
      Enum.min([
        table[{i - 1, j}] + 1,
        table[{i, j - 1}] + 1,
        table[{i - 1, j - 1}] + cost
      ])

    if i > 1 and j > 1 and elem(a, i - 1) == elem(b, j - 2) and elem(a, i - 2) == elem(b, j - 1),
      do: min(best, table[{i - 2, j - 2}] + 1),
      else: best
  end
end
