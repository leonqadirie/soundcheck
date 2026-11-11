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
end
