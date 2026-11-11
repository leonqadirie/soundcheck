defmodule Soundcheck.LineIndex do
  @moduledoc false
  # Converts byte offsets in a source string to `{line, column}` positions:
  # 1-based, with columns counted in codepoints to match Elixir's AST
  # metadata.

  @enforce_keys [:source, :starts]
  defstruct [:source, :starts]

  @type t :: %__MODULE__{source: String.t(), starts: tuple()}

  @spec new(String.t()) :: t()
  def new(source) do
    newlines = for {at, 1} <- :binary.matches(source, "\n"), do: at + 1
    %__MODULE__{source: source, starts: List.to_tuple([0 | newlines])}
  end

  @doc "Returns the position of the byte at `offset`."
  @spec position(t(), non_neg_integer()) :: Soundcheck.Span.position()
  def position(%__MODULE__{source: source, starts: starts}, offset) do
    line = line_of(starts, offset, 0, tuple_size(starts) - 1)
    line_start = elem(starts, line - 1)
    prefix = binary_part(source, line_start, offset - line_start)
    {line, codepoints(prefix) + 1}
  end

  defp codepoints(binary) do
    if String.valid?(binary), do: String.length(binary), else: byte_size(binary)
  end

  # Binary search for the last line start at or before `offset`.
  defp line_of(_starts, _offset, low, high) when low >= high, do: low + 1

  defp line_of(starts, offset, low, high) do
    mid = div(low + high + 1, 2)

    if elem(starts, mid) <= offset,
      do: line_of(starts, offset, mid, high),
      else: line_of(starts, offset, low, mid - 1)
  end
end
