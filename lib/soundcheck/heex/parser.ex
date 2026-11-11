defmodule Soundcheck.Heex.Parser do
  @moduledoc false
  # Builds a `Soundcheck.Heex.Template` tree from `Soundcheck.Heex.Lexer`
  # tokens.
  #
  # The parser never raises on malformed templates. It records an error and
  # recovers:
  #
  #   * an element still open at a closing tag for an outer element, at an
  #     EEx clause boundary, or at the end of input closes with
  #     `close: :missing`;
  #   * a closing tag that matches no open element is dropped;
  #   * an EEx middle or end expression outside a block is dropped;
  #   * an EEx block still open at the end of input closes with
  #     `close: :missing`.

  alias Soundcheck.Heex.Expr
  alias Soundcheck.Heex.Lexer
  alias Soundcheck.Heex.Node
  alias Soundcheck.Heex.OffsetMap
  alias Soundcheck.Heex.Template
  alias Soundcheck.LineIndex
  alias Soundcheck.Span

  @void_elements ~w(area base br col embed hr img input keygen link meta param source track wbr)

  @doc """
  Parses `source` into a template.

  Options:

    * `:file` - the file that holds the template (default `"nofile"`)
    * `:origin` - `:file` (default) or `:sigil`
    * `:offset_map` - maps body positions to file positions (default identity)
    * `:owner` - the `{module, function}` that renders the template
  """
  @spec parse(String.t(), keyword()) :: Template.t()
  def parse(source, opts \\ []) when is_binary(source) do
    ctx = %{
      src: source,
      file: Keyword.get(opts, :file, "nofile"),
      map: Keyword.get(opts, :offset_map, OffsetMap.identity()),
      lines: LineIndex.new(source)
    }

    {root, errors} =
      source
      |> Lexer.tokenize()
      |> build(ctx)

    %Template{
      id: {ctx.file, file_position(ctx, 0)},
      file: ctx.file,
      origin: Keyword.get(opts, :origin, :file),
      owner: Keyword.get(opts, :owner),
      root: root,
      errors: errors
    }
  end

  # ── Tree building ──
  #
  # The stack holds frames, innermost first:
  #   {:root, children}
  #   {:element, open_token, children}
  #   {:block, block, children}   block: %{head, marker, start, clauses, clause}
  # Children and clauses accumulate in reverse.

  defp build(tokens, ctx) do
    {stack, errors} = Enum.reduce(tokens, {[{:root, []}], []}, &step(&1, &2, ctx))
    {[{:root, children}], errors} = close_all(stack, errors, byte_size(ctx.src), ctx)
    {Enum.reverse(children), Enum.reverse(errors)}
  end

  defp step({:text, start, stop}, state, ctx),
    do: append(state, %Node.Text{value: slice(ctx, start, stop), span: span(ctx, start, stop)})

  defp step({:comment, kind, start, stop}, state, ctx),
    do:
      append(state, %Node.Comment{
        value: slice(ctx, start, stop),
        kind: kind,
        span: span(ctx, start, stop)
      })

  defp step({:body_expr, code_start, code_stop, start, stop}, state, ctx) do
    {ast, source} = expr(ctx, code_start, code_stop)
    append(state, %Node.BodyExpr{ast: ast, source: source, span: span(ctx, start, stop)})
  end

  defp step({:eex, :expr, marker, code_start, code_stop, start, stop}, state, ctx) do
    {ast, source} = expr(ctx, code_start, code_stop)

    append(state, %Node.Eex{
      ast: ast,
      source: source,
      marker: marker,
      span: span(ctx, start, stop)
    })
  end

  defp step({:eex, :start, marker, code_start, code_stop, start, stop}, {stack, errors}, ctx) do
    source = slice(ctx, code_start, code_stop)

    block = %{
      head: %{source: source, code_start: code_start, span: span(ctx, start, stop)},
      marker: marker,
      start: start,
      clauses: [],
      clause: %{source: source, start: start, code_start: nil}
    }

    {[{:block, block, []} | stack], errors}
  end

  defp step({:eex, kind, _marker, code_start, code_stop, start, stop}, {stack, errors}, ctx)
       when kind in [:middle, :end] do
    case unwind_to_block(stack, errors, start, ctx) do
      {:ok, [{:block, block, children} | rest], errors} ->
        block = finish_clause(block, children, start, ctx)

        if kind == :middle do
          clause = %{
            source: slice(ctx, code_start, code_stop),
            start: start,
            code_start: code_start
          }

          {[{:block, %{block | clause: clause}, []} | rest], errors}
        else
          closer = slice(ctx, code_start, code_stop)
          append({rest, errors}, block_node(block, stop, :normal, closer, ctx))
        end

      :error ->
        error = %Node.Error{
          message:
            "unexpected `<% #{String.trim(slice(ctx, code_start, code_stop))} %>` outside a block",
          span: span(ctx, start, stop)
        }

        {stack, [error | errors]}
    end
  end

  defp step({:open, name, attrs, start, stop, closing}, state, ctx) do
    kind = kind(name)

    element = %Node.Element{
      tag: name,
      kind: kind,
      attrs: Enum.map(attrs, &attribute(&1, ctx)),
      span: span(ctx, start, stop),
      open_span: span(ctx, start, stop)
    }

    cond do
      closing == :self ->
        append(state, %{element | close: :self})

      kind == :html and String.downcase(name) in @void_elements ->
        append(state, %{element | close: :void})

      true ->
        {stack, errors} = state
        {[{:element, {element, start}, []} | stack], errors}
    end
  end

  defp step({:close, name, start, stop}, {stack, errors}, ctx) do
    if open_element?(stack, name) do
      {stack, errors} = unwind_to_element(stack, errors, name, start, ctx)
      [{:element, {element, _start}, children} | rest] = stack

      element = %{
        element
        | children: Enum.reverse(children),
          span: Span.new(ctx.file, element.span.start, file_position(ctx, stop))
      }

      append({rest, errors}, element)
    else
      error = %Node.Error{
        message: "unmatched closing tag `</#{name}>`",
        span: span(ctx, start, stop)
      }

      {stack, [error | errors]}
    end
  end

  defp step({:error, message, start, stop}, {stack, errors}, ctx),
    do: {stack, [%Node.Error{message: message, span: span(ctx, start, stop)} | errors]}

  defp append({[{type, data, children} | rest], errors}, node),
    do: {[{type, data, [node | children]} | rest], errors}

  defp append({[{:root, children} | rest], errors}, node),
    do: {[{:root, [node | children]} | rest], errors}

  # An element can close only within its EEx clause: the search stops at
  # the nearest block frame.
  defp open_element?([{:element, {%{tag: name}, _start}, _children} | _rest], name), do: true
  defp open_element?([{:element, _open, _children} | rest], name), do: open_element?(rest, name)
  defp open_element?(_stack, _name), do: false

  defp unwind_to_element([{:element, {%{tag: name}, _}, _} | _] = stack, errors, name, _at, _ctx),
    do: {stack, errors}

  defp unwind_to_element([frame | rest], errors, name, at, ctx) do
    {stack, errors} = close_missing(frame, rest, errors, at, ctx)
    unwind_to_element(stack, errors, name, at, ctx)
  end

  defp unwind_to_block([{:block, _, _} | _] = stack, errors, _at, _ctx), do: {:ok, stack, errors}
  defp unwind_to_block([{:root, _} | _], _errors, _at, _ctx), do: :error

  defp unwind_to_block([frame | rest], errors, at, ctx) do
    if Enum.any?(rest, &match?({:block, _, _}, &1)) do
      {stack, errors} = close_missing(frame, rest, errors, at, ctx)
      unwind_to_block(stack, errors, at, ctx)
    else
      :error
    end
  end

  defp close_all([{:root, _}] = stack, errors, _at, _ctx), do: {stack, errors}

  defp close_all([frame | rest], errors, at, ctx) do
    {stack, errors} = close_missing(frame, rest, errors, at, ctx)
    close_all(stack, errors, at, ctx)
  end

  defp close_missing({:element, {element, start}, children}, rest, errors, at, ctx) do
    element = %{
      element
      | children: Enum.reverse(children),
        close: :missing,
        span: Span.new(ctx.file, element.span.start, file_position(ctx, at))
    }

    error = %Node.Error{message: "unclosed tag `<#{element.tag}>`", span: span(ctx, start, at)}
    append({rest, [error | errors]}, element)
  end

  defp close_missing({:block, block, children}, rest, errors, at, ctx) do
    block = finish_clause(block, children, at, ctx)
    error = %Node.Error{message: "unclosed EEx block", span: span(ctx, block.start, at)}
    append({rest, [error | errors]}, block_node(block, at, :missing, "end", ctx))
  end

  defp finish_clause(block, children, stop, ctx) do
    clause = %Node.EexBlock.Clause{
      source: block.clause.source,
      ast: clause_head_ast(ctx, block.clause),
      span: span(ctx, block.clause.start, stop),
      children: Enum.reverse(children)
    }

    %{block | clauses: [clause | block.clauses]}
  end

  defp block_node(block, stop, close, closer, ctx) do
    %{source: source, code_start: code_start, span: head_span} = block.head

    %Node.EexBlock{
      head: %Node.EexBlock.Head{
        ast: block_head_ast(ctx, source, code_start, closer),
        source: source,
        span: head_span
      },
      clauses: Enum.reverse(block.clauses),
      marker: block.marker,
      span: span(ctx, block.start, stop),
      close: close
    }
  end

  # ── Attributes and expressions ──

  defp attribute({name, value, start, stop, name_start, name_stop}, ctx) do
    %Node.Attr{
      name: name,
      value: attr_value(value, ctx),
      span: span(ctx, start, stop),
      name_span: name_start && span(ctx, name_start, name_stop)
    }
  end

  defp attr_value(nil, _ctx), do: nil

  defp attr_value({:string, delimiter, start, stop}, ctx),
    do: {:string, slice(ctx, start, stop), delimiter, span(ctx, start, stop)}

  defp attr_value({:expr, start, stop}, ctx) do
    {ast, source} = expr(ctx, start, stop)
    {:expr, ast, source, span(ctx, start, stop)}
  end

  defp expr(ctx, start, stop) do
    source = slice(ctx, start, stop)
    {Expr.parse(source, body_position(ctx, start), ctx.map, ctx.file), source}
  end

  # Parses `for x <- @xs do` and friends by appending the block's closing
  # code: `end`, or `end)` when the head opens a call such as
  # `Enum.map(@xs, fn x ->`. A block left open at the end of input gets a
  # bare `end`.
  defp block_head_ast(ctx, source, code_start, closer),
    do: Expr.parse(source <> "\n" <> closer, body_position(ctx, code_start), ctx.map, ctx.file)

  # A middle clause head (`{:ok, x} ->`, `@ready? ->`, `x when x > @max ->`)
  # parses on its own once its arrow is gone; `else` and multi-argument
  # heads keep the parse error, which readers skip. The block's head
  # clause is the block head, parsed above.
  defp clause_head_ast(_ctx, %{code_start: nil}), do: nil

  defp clause_head_ast(ctx, %{source: source, code_start: code_start}) do
    code = String.replace(source, ~r/->\s*$/, "")
    Expr.parse(code, body_position(ctx, code_start), ctx.map, ctx.file)
  end

  defp kind("." <> _), do: :local_component
  defp kind(":" <> _), do: :slot
  defp kind(<<c, _::binary>>) when c in ?A..?Z, do: :remote_component
  defp kind(_name), do: :html

  # ── Positions ──

  defp slice(ctx, start, stop), do: binary_part(ctx.src, start, stop - start)

  defp span(ctx, start, stop),
    do: Span.new(ctx.file, file_position(ctx, start), file_position(ctx, stop))

  defp file_position(ctx, offset), do: OffsetMap.to_file(ctx.map, body_position(ctx, offset))

  defp body_position(ctx, offset), do: LineIndex.position(ctx.lines, offset)
end
