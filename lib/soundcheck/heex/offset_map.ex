defmodule Soundcheck.Heex.OffsetMap do
  @moduledoc false
  # Maps positions in a template body to positions in the file that holds it.
  #
  # Body positions are `{line, column}` within the template source string,
  # both 1-based, columns in codepoints. A `.heex` file maps to itself. A
  # `~H` sigil's body is offset from the file, and for heredocs Elixir has
  # stripped the closing delimiter's indentation from every line:
  #
  #   * heredoc (`\"\"\"`, `'''`): body line 1 is the line after the
  #     sigil's opening line; every column shifts by `indentation`.
  #   * single-line delimiter: body line 1 starts on the sigil's line at
  #     the column after `~H` and the delimiter; later lines start at
  #     column 1.
  #
  # Uppercase sigils keep backslashes verbatim, except a backslash before
  # the closing delimiter, which Elixir removes (deprecated since Elixir
  # 1.20). Each removed backslash shifts the rest of its line by one column;
  # `escapes` records them as body positions.

  defstruct line_base: 1, first_line_shift: 0, col_shift: 0, escapes: %{}

  @type position :: {pos_integer(), pos_integer()}

  @type t :: %__MODULE__{
          line_base: pos_integer(),
          first_line_shift: non_neg_integer(),
          col_shift: non_neg_integer(),
          escapes: %{pos_integer() => [pos_integer()]}
        }

  @heredoc_delimiters [~s("""), ~s(''')]

  @pairs %{"(" => ")", "[" => "]", "{" => "}", "<" => ">"}

  @doc "The identity map, for `.heex` files."
  @spec identity() :: t()
  def identity, do: %__MODULE__{}

  @doc """
  Builds the map for a `~H` sigil from its AST metadata and the file's
  source.

  `sigil_meta` is the metadata of the `{:sigil_H, meta, _}` node and
  `body_meta` that of its `{:<<>>, meta, _}` argument, both parsed with
  `columns: true, token_metadata: true`.
  """
  @spec for_sigil(keyword(), keyword(), String.t()) :: t()
  def for_sigil(sigil_meta, body_meta, file_source) do
    delimiter = Keyword.fetch!(sigil_meta, :delimiter)
    line = Keyword.fetch!(sigil_meta, :line)

    if delimiter in @heredoc_delimiters do
      indentation = Keyword.get(body_meta, :indentation, 0)
      %__MODULE__{line_base: line + 1, first_line_shift: indentation, col_shift: indentation}
    else
      # `~H` plus the opening delimiter, all single codepoints.
      content_column = Keyword.fetch!(sigil_meta, :column) + 3
      closing = Map.get(@pairs, delimiter, delimiter)

      %__MODULE__{
        line_base: line,
        first_line_shift: content_column - 1,
        escapes: escapes(file_source, line, content_column, closing)
      }
    end
  end

  @doc "Converts a body position to a file position."
  @spec to_file(t(), position()) :: position()
  def to_file(%__MODULE__{} = map, {line, column}) do
    shift = if line == 1, do: map.first_line_shift, else: map.col_shift

    escaped =
      map.escapes
      |> Map.get(line, [])
      |> Enum.count(&(&1 <= column))

    {map.line_base + line - 1, column + shift + escaped}
  end

  @doc """
  Rewrites every `line`/`column` pair in `ast`'s metadata to file
  positions, including nested token metadata such as `closing:` and
  `end_of_expression:`. `ast` comes from an expression parsed from line 1,
  column 1, whose first codepoint sits at body position `start`.
  """
  @spec remap_ast(Macro.t(), t(), position()) :: Macro.t()
  def remap_ast(ast, %__MODULE__{} = map, start) do
    Macro.prewalk(ast, fn
      {form, meta, args} when is_list(meta) -> {form, remap_meta(meta, map, start), args}
      other -> other
    end)
  end

  defp remap_meta(meta, map, start) do
    meta = remap_position(meta, map, start)

    Enum.map(meta, fn
      {key, nested} when is_list(nested) and key != :line and key != :column ->
        if Keyword.keyword?(nested) and Keyword.has_key?(nested, :line),
          do: {key, remap_position(nested, map, start)},
          else: {key, nested}

      pair ->
        pair
    end)
  end

  defp remap_position(meta, map, start) do
    case {Keyword.fetch(meta, :line), Keyword.fetch(meta, :column)} do
      {{:ok, line}, {:ok, column}} ->
        {file_line, file_column} = to_file(map, in_body({line, column}, start))
        meta |> Keyword.put(:line, file_line) |> Keyword.put(:column, file_column)

      {{:ok, line}, :error} ->
        {file_line, _column} = to_file(map, in_body({line, 1}, start))
        Keyword.put(meta, :line, file_line)

      _ ->
        meta
    end
  end

  # The body position of a position within an expression that starts at
  # `start`: only the expression's first line shares a line with what
  # precedes it, so only that line's columns shift.
  defp in_body({1, column}, {start_line, start_column}),
    do: {start_line, column + start_column - 1}

  defp in_body({line, column}, {start_line, _start_column}), do: {start_line + line - 1, column}

  # Walks the raw source from the body's first codepoint to the closing
  # delimiter and records, per body line, the body column of each
  # delimiter that a removed backslash preceded.
  defp escapes(file_source, line, content_column, closing) do
    file_source
    |> String.split("\n")
    |> Enum.drop(line - 1)
    |> Enum.join("\n")
    |> String.slice((content_column - 1)..-1//1)
    |> scan_escapes(closing, {1, 1}, %{})
    |> Map.new(fn {body_line, columns} -> {body_line, Enum.sort(columns)} end)
  end

  defp scan_escapes(raw, closing, {body_line, body_col}, acc) do
    case String.next_codepoint(raw) do
      nil ->
        acc

      {"\\", rest} ->
        case String.next_codepoint(rest) do
          {^closing, after_delimiter} ->
            acc = Map.update(acc, body_line, [body_col], &[body_col | &1])
            scan_escapes(after_delimiter, closing, {body_line, body_col + 1}, acc)

          {_escaped, after_escaped} ->
            scan_escapes(after_escaped, closing, {body_line, body_col + 2}, acc)

          nil ->
            acc
        end

      {^closing, _rest} ->
        acc

      {"\n", rest} ->
        scan_escapes(rest, closing, {body_line + 1, 1}, acc)

      {_char, rest} ->
        scan_escapes(rest, closing, {body_line, body_col + 1}, acc)
    end
  end
end
