defmodule Soundcheck.Span do
  @moduledoc false
  # A source range in absolute file coordinates.
  #
  # Lines and columns are 1-based. Columns count Unicode codepoints, which
  # matches Elixir's own AST column metadata. `stop` is exclusive.

  @enforce_keys [:file, :start, :stop]
  defstruct [:file, :start, :stop]

  @type position :: {line :: pos_integer(), column :: pos_integer()}
  @type t :: %__MODULE__{file: Path.t(), start: position(), stop: position()}

  @spec new(Path.t(), position(), position()) :: t()
  def new(file, start, stop), do: %__MODULE__{file: file, start: start, stop: stop}

  @doc """
  The span of `written` from the line and column in an AST node's
  `meta`, for source text that `written` reproduces exactly.
  """
  @spec covering(Path.t(), keyword(), String.t()) :: t()
  def covering(file, meta, written) do
    {line, column} = {meta[:line], meta[:column]}
    new(file, {line, column}, {line, column + String.length(written)})
  end

  @doc "Returns `true` when `position` lies within `span` (start inclusive, stop exclusive)."
  @spec contains?(t(), position()) :: boolean()
  def contains?(%__MODULE__{start: start, stop: stop}, position),
    do: position >= start and position < stop
end
