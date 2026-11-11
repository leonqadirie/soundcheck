defmodule Soundcheck.Output.Encoder do
  @moduledoc false
  # Encodes a term as indented JSON for the JSON and SARIF renderers.
  #
  # Elixir's `JSON` module encodes without whitespace. This module adds the
  # layout: two spaces per level, one object entry or array element per
  # line. `JSON` encodes every scalar and every key, so escaping is its.

  @doc "Encodes `term`: maps, lists, and whatever `JSON.encode!/1` accepts as a scalar."
  @spec encode(term()) :: String.t()
  def encode(term), do: term |> format("\n") |> :erlang.iolist_to_binary()

  # `newline` is a line break plus the indentation of the enclosing level.
  defp format(map, newline) when is_map(map) and not is_struct(map) and map_size(map) > 0 do
    inner = newline <> "  "

    entries =
      Enum.map_intersperse(map, [",", inner], fn {key, value} ->
        [JSON.encode_to_iodata!(to_string(key)), ": ", format(value, inner)]
      end)

    ["{", inner, entries, newline, "}"]
  end

  defp format([_ | _] = list, newline) do
    inner = newline <> "  "
    ["[", inner, Enum.map_intersperse(list, [",", inner], &format(&1, inner)), newline, "]"]
  end

  defp format(scalar, _newline), do: JSON.encode_to_iodata!(scalar)
end
