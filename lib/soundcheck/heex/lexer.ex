defmodule Soundcheck.Heex.Lexer do
  @moduledoc false
  # Splits HEEx source into tokens, recovering from errors instead of
  # raising.
  #
  # Positions are byte offsets into the source: `start` inclusive, `stop`
  # exclusive. `Soundcheck.Heex.Parser` turns them into file positions.
  #
  # Tokens:
  #
  #   * `{:text, start, stop}`
  #   * `{:open, name, attrs, start, stop, closing}`, `closing` `:normal` or `:self`
  #   * `{:close, name, start, stop}`
  #   * `{:body_expr, code_start, code_stop, start, stop}` for `{expr}`
  #   * `{:eex, kind, marker, code_start, code_stop, start, stop}`, `kind` one of
  #     `:expr`, `:start`, `:middle`, `:end`; `marker` `"="` or `""`
  #   * `{:comment, kind, start, stop}`, `kind` `:html` or `:eex`
  #   * `{:error, message, start, stop}`
  #
  # An attribute is `{name, value, start, stop, name_start, name_stop}`, where
  # `name` is a binary or `:root` (`{@rest}`, with `nil` name positions), and
  # `value` is `{:string, delimiter, value_start, value_stop}`,
  # `{:expr, code_start, code_stop}`, or `nil`.
  #
  # Every scanning rule mirrors LiveView's tokenizer, so both split any
  # template LiveView accepts the same way: an embedded Elixir expression
  # ends at the brace that balances the opening one, counting braces inside
  # strings too; `<script>` and `<style>` bodies are raw text; and an element
  # with `phx-no-curly-interpolation` turns `{` into text until the tag depth
  # returns to where it started.

  @whitespace [?\s, ?\t, ?\n, ?\r, ?\f]

  @raw_text_tags ["script", "style"]

  defguardp is_whitespace(c) when c in @whitespace

  defguardp is_name_char(c)
            when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in [?_, ?-, ?., ?:]

  defguardp is_attr_name_char(c)
            when not is_whitespace(c) and c not in [?=, ?>, ?/, ?{, ?", ?', ?<]

  @type offset :: non_neg_integer()

  @type attr_value ::
          {:string, delimiter :: ?" | ?', offset(), offset()} | {:expr, offset(), offset()} | nil

  @type attr ::
          {name :: String.t() | :root, attr_value(), start :: offset(), stop :: offset(),
           name_start :: offset() | nil, name_stop :: offset() | nil}

  @type token ::
          {:text, offset(), offset()}
          | {:open, name :: String.t(), [attr()], offset(), offset(), :normal | :self}
          | {:close, name :: String.t(), offset(), offset()}
          | {:body_expr, offset(), offset(), offset(), offset()}
          | {:eex, :expr | :start | :middle | :end, marker :: String.t(), offset(), offset(),
             offset(), offset()}
          | {:comment, :html | :eex, offset(), offset()}
          | {:error, message :: String.t(), offset(), offset()}

  @spec tokenize(String.t()) :: [token()]
  def tokenize(source) when is_binary(source) do
    source
    |> text(0, source, 0, [], nil)
    |> Enum.reverse()
  end

  # ── Text mode ──
  #
  # `no_curly` is `nil`, or the tag depth inside a subtree opened by an
  # element with `phx-no-curly-interpolation`.

  defp text("", i, _src, text_start, acc, _no_curly), do: flush(acc, text_start, i)

  defp text("<%!--" <> _, i, src, text_start, acc, no_curly) do
    acc = flush(acc, text_start, i)
    {token, next} = delimited(src, i, i + 5, "--%>", :eex, "unclosed EEx comment `<%!--`")
    resume(src, next, [token | acc], no_curly)
  end

  defp text("<%%" <> _, i, src, text_start, acc, no_curly),
    do: text(rest_at(src, i + 3), i + 3, src, text_start, acc, no_curly)

  defp text("<%#" <> _, i, src, text_start, acc, no_curly) do
    acc = flush(acc, text_start, i)
    {token, next} = delimited(src, i, i + 3, "%>", :eex, "unclosed EEx comment `<%#`")
    resume(src, next, [token | acc], no_curly)
  end

  defp text("<%" <> _, i, src, text_start, acc, no_curly) do
    acc = flush(acc, text_start, i)
    {token, next} = eex(src, i)
    resume(src, next, [token | acc], no_curly)
  end

  defp text("<!--" <> _, i, src, text_start, acc, no_curly) do
    acc = flush(acc, text_start, i)
    {token, next} = delimited(src, i, i + 4, "-->", :html, "unclosed HTML comment `<!--`")
    resume(src, next, [token | acc], no_curly)
  end

  defp text("</" <> _, i, src, text_start, acc, no_curly) do
    acc = flush(acc, text_start, i)
    {token, next} = close_tag(src, i)
    resume(src, next, [token | acc], track_close(no_curly, token))
  end

  defp text(<<?<, c, _::binary>>, i, src, text_start, acc, no_curly)
       when c in ?a..?z or c in ?A..?Z or c in [?., ?:] do
    acc = flush(acc, text_start, i)
    {open, tokens, next} = open_tag(src, i)
    resume(src, next, tokens ++ acc, track_open(no_curly, open))
  end

  defp text("{" <> _, i, src, text_start, acc, nil) do
    acc = flush(acc, text_start, i)

    case expr(rest_at(src, i + 1), i + 1, 0) do
      {:ok, close} ->
        resume(src, close + 1, [{:body_expr, i + 1, close, i, close + 1} | acc], nil)

      :error ->
        stop = byte_size(src)
        [{:error, "unclosed `{` expression", i, stop} | acc]
    end
  end

  defp text(<<_, rest::binary>>, i, src, text_start, acc, no_curly),
    do: text(rest, i + 1, src, text_start, acc, no_curly)

  defp resume(src, i, acc, no_curly), do: text(rest_at(src, i), i, src, i, acc, no_curly)

  defp flush(acc, start, stop) when stop > start, do: [{:text, start, stop} | acc]
  defp flush(acc, _start, _stop), do: acc

  # ── Comments ──

  defp delimited(src, start, content_start, terminator, kind, message) do
    case find(src, terminator, content_start) do
      {:ok, at} ->
        stop = at + byte_size(terminator)
        {{:comment, kind, start, stop}, stop}

      :error ->
        stop = byte_size(src)
        {{:error, message, start, stop}, stop}
    end
  end

  # ── EEx ──

  defp eex(src, start) do
    {marker, code_start} =
      case binary_part(src, start + 2, min(1, byte_size(src) - start - 2)) do
        "=" -> {"=", start + 3}
        _ -> {"", start + 2}
      end

    case find(src, "%>", code_start) do
      {:ok, at} ->
        code = binary_part(src, code_start, at - code_start)
        {{:eex, classify(code), marker, code_start, at, start, at + 2}, at + 2}

      :error ->
        stop = byte_size(src)
        {{:error, "unclosed EEx tag `<%`", start, stop}, stop}
    end
  end

  # Mirrors how EEx groups expressions into blocks: an expression ending in
  # `do` or `->` (outside a middle clause) opens a block, `end` closes it, and
  # `else`/`catch`/`rescue`/`after` or a clause ending in `->` continues it.
  defp classify(code) do
    trimmed = String.trim(code)

    cond do
      Regex.match?(~r/^end\b/, trimmed) -> :end
      Regex.match?(~r/^(else|catch|rescue|after)\b/, trimmed) -> :middle
      Regex.match?(~r/(\bdo|\bfn\b.*->)$/s, trimmed) -> :start
      String.ends_with?(trimmed, "->") -> :middle
      true -> :expr
    end
  end

  # ── Tags ──

  defp close_tag(src, start) do
    {name, after_name} = name(src, start + 2)
    after_space = skip_whitespace(src, after_name)

    case rest_at(src, after_space) do
      ">" <> _ when name != "" ->
        {{:close, name, start, after_space + 1}, after_space + 1}

      _ ->
        stop = max(after_space, start + 2)
        {{:error, "malformed closing tag", start, stop}, stop}
    end
  end

  # Returns the open-tag token, all tokens it produced in reverse order
  # (the open tag, errors raised while reading attributes, and the tokens
  # of a `<script>`/`<style>` body), and the offset to resume at.
  defp open_tag(src, start) do
    {name, after_name} = name(src, start + 1)

    case attrs(src, after_name, [], []) do
      {:ok, attrs, closing, stop, errors} ->
        open = {:open, name, Enum.reverse(attrs), start, stop, closing}
        {raw, next} = raw_text(src, name, closing, stop)
        {open, raw ++ errors ++ [open], next}

      {:eof, attrs, errors} ->
        stop = byte_size(src)
        open = {:open, name, Enum.reverse(attrs), start, stop, :normal}
        error = {:error, "unclosed tag `<#{name}`", start, stop}
        {open, [error | errors] ++ [open], stop}
    end
  end

  # `<script>` and `<style>` bodies are raw text, except for EEx tags:
  # LiveView runs `EEx.tokenize/2` before its HTML tokenizer, so
  # `<%= ... %>` inside them still becomes an expression. Returns tokens in
  # reverse order and the offset where the body ends.
  defp raw_text(src, name, :normal, from) when name in @raw_text_tags do
    stop =
      case Regex.run(~r/<\/#{name}\s*>/i, src, offset: from, return: :index) do
        [{at, _length}] -> at
        nil -> byte_size(src)
      end

    {raw_segments(src, from, stop, from, []), stop}
  end

  defp raw_text(_src, _name, _closing, from), do: {[], from}

  defp raw_segments(_src, i, stop, text_start, acc) when i >= stop,
    do: flush(acc, text_start, stop)

  defp raw_segments(src, i, stop, text_start, acc) do
    case find(src, "<%", i) do
      {:ok, at} when at < stop ->
        acc = flush(acc, text_start, at)

        {token, next} =
          case rest_at(src, at) do
            "<%!--" <> _ ->
              delimited(src, at, at + 5, "--%>", :eex, "unclosed EEx comment `<%!--`")

            "<%#" <> _ ->
              delimited(src, at, at + 3, "%>", :eex, "unclosed EEx comment `<%#`")

            _ ->
              eex(src, at)
          end

        raw_segments(src, next, stop, next, [token | acc])

      _ ->
        flush(acc, text_start, stop)
    end
  end

  defp attrs(src, i, acc, errors) do
    i = skip_whitespace(src, i)

    case rest_at(src, i) do
      "" ->
        {:eof, acc, errors}

      "/>" <> _ ->
        {:ok, acc, :self, i + 2, errors}

      ">" <> _ ->
        {:ok, acc, :normal, i + 1, errors}

      "{" <> _ ->
        case expr(rest_at(src, i + 1), i + 1, 0) do
          {:ok, close} ->
            attr = {:root, {:expr, i + 1, close}, i, close + 1, nil, nil}
            attrs(src, close + 1, [attr | acc], errors)

          :error ->
            {:eof, acc, [{:error, "unclosed `{` in attribute", i, byte_size(src)} | errors]}
        end

      _ ->
        attribute(src, i, acc, errors)
    end
  end

  defp attribute(src, start, acc, errors) do
    {name, name_stop} = attr_name(src, start)

    if name == "" do
      # A character that cannot start an attribute, such as a stray quote.
      error = {:error, "unexpected character in tag", start, start + 1}
      attrs(src, start + 1, acc, [error | errors])
    else
      after_name = skip_whitespace(src, name_stop)

      case rest_at(src, after_name) do
        "=" <> _ ->
          attr_value(
            src,
            name,
            start,
            name_stop,
            skip_whitespace(src, after_name + 1),
            acc,
            errors
          )

        _ ->
          attrs(src, name_stop, [{name, nil, start, name_stop, start, name_stop} | acc], errors)
      end
    end
  end

  defp attr_value(src, name, start, name_stop, i, acc, errors) do
    case rest_at(src, i) do
      <<quote, _::binary>> when quote in [?", ?'] ->
        case find(src, <<quote>>, i + 1) do
          {:ok, close} ->
            attr = {name, {:string, quote, i + 1, close}, start, close + 1, start, name_stop}
            attrs(src, close + 1, [attr | acc], errors)

          :error ->
            {:eof, acc, [{:error, "unclosed attribute value", i, byte_size(src)} | errors]}
        end

      "{" <> _ ->
        case expr(rest_at(src, i + 1), i + 1, 0) do
          {:ok, close} ->
            attr = {name, {:expr, i + 1, close}, start, close + 1, start, name_stop}
            attrs(src, close + 1, [attr | acc], errors)

          :error ->
            {:eof, acc, [{:error, "unclosed `{` in attribute", i, byte_size(src)} | errors]}
        end

      _ ->
        error = {:error, "expected attribute value after `=`", start, i}
        attrs(src, i, [{name, nil, start, name_stop, start, name_stop} | acc], [error | errors])
    end
  end

  # LiveView disables `{` interpolation from an element with
  # `phx-no-curly-interpolation` until its tag depth returns to zero. The
  # depth counts every `>`-terminated open tag, void elements included, and
  # every closing tag; `<script>` and `<style>` do not count.
  defp track_open(nil, {:open, name, attrs, _start, _stop, :normal}) do
    if name not in @raw_text_tags and
         Enum.any?(attrs, &match?({"phx-no-curly-interpolation", _, _, _, _, _}, &1)),
       do: 1
  end

  defp track_open(depth, {:open, name, _attrs, _start, _stop, :normal})
       when is_integer(depth) and name not in @raw_text_tags, do: depth + 1

  defp track_open(no_curly, _token), do: no_curly

  defp track_close(1, {:close, _name, _start, _stop}), do: nil
  defp track_close(depth, {:close, _name, _start, _stop}) when is_integer(depth), do: depth - 1
  defp track_close(no_curly, _token), do: no_curly

  # ── Elixir expressions ──
  #
  # Mirrors LiveView's tokenizer: an expression ends at the `}` that
  # balances the opening `{`, counting every brace, including braces inside
  # strings, and skipping only the escapes `\{` and `\}`. A template whose
  # strings hold unbalanced braces does not compile under LiveView either.
  # `i` is the offset of the first byte of `rest`.

  defp expr("", _i, _depth), do: :error
  defp expr("}" <> _, i, 0), do: {:ok, i}
  defp expr("\\}" <> rest, i, depth), do: expr(rest, i + 2, depth)
  defp expr("\\{" <> rest, i, depth), do: expr(rest, i + 2, depth)
  defp expr("}" <> rest, i, depth), do: expr(rest, i + 1, depth - 1)
  defp expr("{" <> rest, i, depth), do: expr(rest, i + 1, depth + 1)
  defp expr(<<_, rest::binary>>, i, depth), do: expr(rest, i + 1, depth)

  # ── Helpers ──

  defp rest_at(src, i), do: binary_part(src, i, byte_size(src) - i)

  defp find(src, pattern, from) do
    case :binary.match(src, pattern, scope: {from, byte_size(src) - from}) do
      {at, _length} -> {:ok, at}
      :nomatch -> :error
    end
  end

  # Each scanner takes the offset of the first byte of `rest` and returns
  # the offset of the first byte it does not accept.

  defp name(src, start) do
    stop = name_end(rest_at(src, start), start)
    {binary_part(src, start, stop - start), stop}
  end

  defp name_end(<<c, rest::binary>>, i) when is_name_char(c), do: name_end(rest, i + 1)
  defp name_end(_rest, i), do: i

  defp attr_name(src, start) do
    stop = attr_name_end(rest_at(src, start), start)
    {binary_part(src, start, stop - start), stop}
  end

  defp attr_name_end(<<c, rest::binary>>, i) when is_attr_name_char(c),
    do: attr_name_end(rest, i + 1)

  defp attr_name_end(_rest, i), do: i

  defp skip_whitespace(src, i), do: whitespace_end(rest_at(src, i), i)

  defp whitespace_end(<<c, rest::binary>>, i) when is_whitespace(c),
    do: whitespace_end(rest, i + 1)

  defp whitespace_end(_rest, i), do: i
end
