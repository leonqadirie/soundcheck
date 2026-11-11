defmodule Soundcheck.Suppression do
  @moduledoc false
  # `soundcheck:disable-*` comments, which silence findings in Elixir, HEEx,
  # and JavaScript files alike:
  #
  #     # soundcheck:disable-next-line SC101 -- pushed by an external widget
  #     <%!-- soundcheck:disable-line UndefinedHook -- registered by a CDN script --%>
  #     // soundcheck:disable-file SC1xx
  #
  # The directive names one or more selectors, separated by commas or
  # spaces, and may end with ` -- reason`. A selector is a rule id
  # (`SC101`), a family wildcard (`SC1xx` matches `SC101` and `SC1002`), or a
  # check's short name (`UnhandledEvent`).
  #
  # In `.ex` and `.exs` files a directive counts only in a `#` comment or
  # inside a `~H` sigil, so examples in docs and string literals suppress
  # nothing.
  #
  # `disable-next-line` covers the line after the comment, `disable-line`
  # its own line, `disable-file` the whole file. A finding is suppressed when
  # a directive covers its primary or its anchor location.
  #
  # soundcheck applies these before projecting findings onto Credo issues,
  # so they work for `.heex` templates, which Credo's own `credo:disable-*`
  # comments cannot reach.

  alias Soundcheck.Diagnostic
  alias Soundcheck.Span

  @directive ~r/soundcheck:disable-(next-line|line|file)(?:\s+([^\n]*?))?(?:\s*--\s(.*?))?\s*(?:--%>|\*\/|-->)?\s*$/

  defmodule Directive do
    @moduledoc false
    # One `soundcheck:disable-*` comment. `column` and `length` locate the
    # directive text on its line; `reason` is the text after `--`, if any.
    @enforce_keys [:scope, :line, :column, :length, :selectors, :reason]
    defstruct [:scope, :line, :column, :length, :selectors, :reason]

    @type t :: %__MODULE__{
            scope: :next_line | :line | :file,
            line: pos_integer(),
            column: pos_integer(),
            length: pos_integer(),
            selectors: [String.t()],
            reason: String.t() | nil
          }
  end

  @type directive :: Directive.t()

  @doc """
  Parses the directives in `source`. When `file` names an Elixir file,
  keeps only directives on lines that hold a comment or `~H` content.
  """
  @spec directives(String.t(), Path.t() | nil) :: [directive()]
  def directives(source, file \\ nil) do
    lines = directive_lines(source, file)

    source
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.filter(fn {_text, line} -> lines == :all or MapSet.member?(lines, line) end)
    |> Enum.flat_map(fn {text, line} ->
      case Regex.run(@directive, text, return: :index) do
        [{start, _length} | groups] ->
          [scope, selectors, reason] = groups |> Enum.map(&slice(text, &1)) |> pad(3)

          directive_text =
            text |> binary_part(start, byte_size(text) - start) |> String.trim_trailing()

          [
            %Directive{
              scope: parse_scope(scope),
              line: line,
              column: String.length(binary_part(text, 0, start)) + 1,
              length: String.length(directive_text),
              selectors: split(selectors || ""),
              reason: if(reason not in [nil, ""], do: reason)
            }
          ]

        nil ->
          []
      end
    end)
  end

  @doc """
  Removes suppressed diagnostics. `sources` maps a file to its directives;
  files missing from the map are read from disk.
  """
  @spec reject([Diagnostic.t()], %{Path.t() => [directive()]}) :: [Diagnostic.t()]
  def reject(diagnostics, sources \\ %{}) do
    files = diagnostics |> Enum.flat_map(&files/1) |> Enum.uniq()
    directives = Map.new(files, &{&1, Map.get_lazy(sources, &1, fn -> file_directives(&1) end)})

    Enum.reject(diagnostics, &suppressed?(&1, directives))
  end

  @doc "Returns `true` when `selector` names the rule of `diagnostic`."
  @spec matches?(String.t(), Diagnostic.t()) :: boolean()
  def matches?(selector, %Diagnostic{id: id, rule: rule}) do
    cond do
      selector == id ->
        true

      String.ends_with?(selector, "x") ->
        String.starts_with?(id, String.trim_trailing(selector, "x"))

      true ->
        rule |> Module.split() |> List.last() == selector
    end
  end

  defp suppressed?(%Diagnostic{} = diagnostic, directives) do
    [diagnostic.primary, diagnostic.anchor]
    |> Enum.reject(&is_nil/1)
    |> Enum.any?(fn %Span{file: file, start: {line, _column}} ->
      directives
      |> Map.get(file, [])
      |> Enum.any?(
        &(covers?(&1, line) and
            Enum.any?(&1.selectors, fn selector -> matches?(selector, diagnostic) end))
      )
    end)
  end

  defp covers?(%Directive{scope: :file}, _line), do: true
  defp covers?(%Directive{scope: :line, line: line}, line), do: true

  defp covers?(%Directive{scope: :next_line, line: comment_line}, line),
    do: line == comment_line + 1

  defp covers?(_directive, _line), do: false

  defp files(%Diagnostic{primary: primary, anchor: anchor}),
    do: for(%Span{file: file} <- [primary, anchor], do: file)

  @doc "Parses the directives in `file`, or none when it cannot be read."
  @spec file_directives(Path.t()) :: [directive()]
  def file_directives(file) do
    case File.read(file) do
      {:ok, source} -> directives(source, file)
      {:error, _reason} -> []
    end
  end

  # Elixir strings and docs may quote directives; only comments and `~H`
  # bodies hold real ones. A file that does not parse keeps every line.
  defp directive_lines(source, file) when is_binary(file) do
    if Path.extname(file) in [".ex", ".exs"], do: elixir_lines(source), else: :all
  end

  defp directive_lines(_source, nil), do: :all

  defp elixir_lines(source) do
    case Code.string_to_quoted_with_comments(source, columns: true, token_metadata: true) do
      {:ok, ast, comments} ->
        sigil_lines = ast |> Macro.prewalker() |> Enum.flat_map(&sigil_lines/1)
        MapSet.new(Enum.map(comments, & &1.line) ++ sigil_lines)

      {:error, _reason} ->
        :all
    end
  end

  # A `~H` body spans its opening line through its closing delimiter.
  defp sigil_lines({:sigil_H, meta, [{:<<>>, _, [body]}, _modifiers]}) when is_binary(body) do
    first = meta[:line]
    Enum.to_list(first..(first + newlines(body) + 1))
  end

  defp sigil_lines(_node), do: []

  defp newlines(text), do: text |> :binary.matches("\n") |> length()

  defp parse_scope("next-line"), do: :next_line
  defp parse_scope("line"), do: :line
  defp parse_scope("file"), do: :file

  # Unmatched optional groups come back as `{-1, 0}` or are left off.
  defp slice(_text, {-1, 0}), do: nil
  defp slice(text, {start, length}), do: binary_part(text, start, length)

  defp pad(list, size), do: list ++ List.duplicate(nil, size - length(list))

  defp split(selectors), do: String.split(selectors, [",", " "], trim: true)
end
