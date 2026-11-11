defmodule Soundcheck.Heex.Expr do
  @moduledoc false
  # Parses an expression embedded in a template into Elixir AST with file
  # positions.
  #
  # The expression is parsed from its own line 1, column 1. Every position
  # in the resulting metadata is then moved to where the expression starts
  # in the template body and mapped through the template's
  # `Soundcheck.Heex.OffsetMap`. `Code.string_to_quoted/2` takes `line:` and
  # `column:` offsets, but Elixir 1.18 and earlier add the column offset to
  # every line instead of the first one only.

  alias Soundcheck.Heex.Node
  alias Soundcheck.Heex.OffsetMap

  @spec parse(String.t(), OffsetMap.position(), OffsetMap.t(), Path.t()) :: Node.expr()
  def parse(code, start, %OffsetMap{} = map, file) do
    opts = [columns: true, token_metadata: true, file: file, emit_warnings: false]

    case Code.string_to_quoted(code, opts) do
      {:ok, ast} -> OffsetMap.remap_ast(ast, map, start)
      {:error, reason} -> {:error, reason}
    end
  end
end
