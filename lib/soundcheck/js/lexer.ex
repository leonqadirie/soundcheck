defmodule Soundcheck.JS.Lexer do
  @moduledoc false
  # Splits JavaScript or TypeScript source into the tokens the hook
  # extractor needs.
  #
  # Tokens are `{type, value, start, stop}` with byte offsets (`stop`
  # exclusive):
  #
  #   * `:ident` - identifiers and keywords, value the name
  #   * `:string` - quoted strings, value the content with escapes resolved
  #   * `:template` - template literals; value the content when the literal
  #     has no `${}` substitution, `:dynamic` otherwise
  #   * `:punct` - punctuation and operators, value the operator text
  #   * `:number`, `:regex` - value `nil`
  #
  # Comments and whitespace produce no tokens. A `/` starts a regex literal
  # unless the previous token ends an expression (an identifier other than an
  # operator keyword, a literal, or a closing bracket), the usual heuristic.
  # TypeScript type annotations pass through as ordinary tokens. The lexer
  # never raises: an unterminated string, template, comment, or regex ends at
  # the end of input.

  @type offset :: non_neg_integer()

  @type token ::
          {:ident | :string | :punct, String.t(), offset(), offset()}
          | {:template, String.t() | :dynamic, offset(), offset()}
          | {:number | :regex, nil, offset(), offset()}

  # Multi-character operators. A longer operator comes before any operator
  # that is its prefix.
  @puncts ~w(... => === !== == != <= >= && || ?? ?. ++ --)

  # Keywords after which `/` starts a regex rather than dividing.
  @regex_after_keywords ~w(return typeof instanceof in of new delete void throw case do else yield await)

  defguardp is_ident_char(c) when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c in [?_, ?$]

  @spec tokenize(String.t()) :: [token()]
  def tokenize(source) when is_binary(source), do: source |> scan(0, nil, []) |> Enum.reverse()

  defp scan("", _i, _prev, acc), do: acc

  defp scan(<<c, rest::binary>>, i, prev, acc) when c in [?\s, ?\t, ?\n, ?\r, ?\f, ?\v],
    do: scan(rest, i + 1, prev, acc)

  defp scan("//" <> rest, i, prev, acc) do
    skip = until(rest, "\n")
    scan(skip_bytes(rest, skip), i + 2 + skip, prev, acc)
  end

  defp scan("/*" <> rest, i, prev, acc) do
    skip = until(rest, "*/")
    skip = if skip < byte_size(rest), do: skip + 2, else: skip
    scan(skip_bytes(rest, skip), i + 2 + skip, prev, acc)
  end

  defp scan(<<quote, rest::binary>>, i, _prev, acc) when quote in [?", ?'] do
    {value, length} = string(rest, quote)
    token = {:string, value, i, i + 1 + length}
    scan(skip_bytes(rest, length), i + 1 + length, token, [token | acc])
  end

  defp scan("`" <> rest, i, _prev, acc) do
    {value, length} = template(rest, "", false, 0)
    token = {:template, value, i, i + 1 + length}
    scan(skip_bytes(rest, length), i + 1 + length, token, [token | acc])
  end

  defp scan("/" <> rest, i, prev, acc) do
    if regex_allowed?(prev) do
      length = regex(rest, false, 0)
      token = {:regex, nil, i, i + 1 + length}
      scan(skip_bytes(rest, length), i + 1 + length, token, [token | acc])
    else
      punct("/", rest, i, acc)
    end
  end

  defp scan(<<c, _::binary>> = source, i, _prev, acc)
       when c in ?a..?z or c in ?A..?Z or c in [?_, ?$] do
    {name, rest} = split_at(source, ident_length(source, 0))
    token = {:ident, name, i, i + byte_size(name)}
    scan(rest, i + byte_size(name), token, [token | acc])
  end

  defp scan(<<c, _::binary>> = source, i, _prev, acc) when c in ?0..?9 do
    {digits, rest} = split_at(source, number_length(source, 0))
    token = {:number, nil, i, i + byte_size(digits)}
    scan(rest, i + byte_size(digits), token, [token | acc])
  end

  # One clause per multi-character operator, in `@puncts` order, so a longer
  # operator matches before its prefix.
  for op <- @puncts do
    defp scan(unquote(op) <> rest, i, _prev, acc), do: punct(unquote(op), rest, i, acc)
  end

  defp scan(<<c::utf8, rest::binary>>, i, _prev, acc), do: punct(<<c::utf8>>, rest, i, acc)

  # A byte that is not valid UTF-8 becomes a one-byte token.
  defp scan(<<c, rest::binary>>, i, _prev, acc), do: punct(<<c>>, rest, i, acc)

  defp punct(op, rest, i, acc) do
    token = {:punct, op, i, i + byte_size(op)}
    scan(rest, i + byte_size(op), token, [token | acc])
  end

  defp regex_allowed?(nil), do: true
  defp regex_allowed?({:ident, name, _, _}), do: name in @regex_after_keywords
  defp regex_allowed?({:punct, op, _, _}), do: op not in [")", "]", "}"]
  defp regex_allowed?(_literal), do: false

  # Returns the string content (escapes resolved) and the number of bytes
  # consumed after the opening quote, including the closing quote.
  defp string(source, quote), do: string(source, quote, "", 0)

  defp string("", _quote, acc, n), do: {acc, n}
  defp string(<<quote, _::binary>>, quote, acc, n), do: {acc, n + 1}

  defp string(<<?\\, c::utf8, rest::binary>>, quote, acc, n),
    do: string(rest, quote, <<acc::binary, c::utf8>>, n + 1 + byte_size(<<c::utf8>>))

  defp string(<<?\n, _::binary>>, _quote, acc, n), do: {acc, n}

  defp string(<<c, rest::binary>>, quote, acc, n),
    do: string(rest, quote, <<acc::binary, c>>, n + 1)

  # Template literal: returns `{content | :dynamic, bytes consumed}`.
  # `${ ... }` substitutions may nest braces, strings, and templates.
  defp template("", acc, dynamic?, n), do: {template_value(acc, dynamic?), n}
  defp template("`" <> _, acc, dynamic?, n), do: {template_value(acc, dynamic?), n + 1}

  defp template(<<?\\, c::utf8, rest::binary>>, acc, dynamic?, n),
    do: template(rest, <<acc::binary, c::utf8>>, dynamic?, n + 1 + byte_size(<<c::utf8>>))

  defp template("${" <> rest, acc, _dynamic?, n) do
    skip = substitution(rest, 0, 0)
    template(skip_bytes(rest, skip), acc, true, n + 2 + skip)
  end

  defp template(<<c, rest::binary>>, acc, dynamic?, n),
    do: template(rest, <<acc::binary, c>>, dynamic?, n + 1)

  defp template_value(_acc, true), do: :dynamic
  defp template_value(acc, false), do: acc

  # Bytes up to and including the `}` that closes a `${` substitution.
  defp substitution("", _depth, n), do: n
  defp substitution("}" <> _, 0, n), do: n + 1
  defp substitution("}" <> rest, depth, n), do: substitution(rest, depth - 1, n + 1)
  defp substitution("{" <> rest, depth, n), do: substitution(rest, depth + 1, n + 1)

  defp substitution(<<quote, rest::binary>>, depth, n) when quote in [?", ?'] do
    {_value, length} = string(rest, quote)
    substitution(skip_bytes(rest, length), depth, n + 1 + length)
  end

  defp substitution("`" <> rest, depth, n) do
    {_value, length} = template(rest, "", false, 0)
    substitution(skip_bytes(rest, length), depth, n + 1 + length)
  end

  defp substitution(<<_, rest::binary>>, depth, n), do: substitution(rest, depth, n + 1)

  # Regex literal body and flags; `/` inside a character class does not end it.
  defp regex("", _class?, n), do: n
  defp regex(<<?\n, _::binary>>, _class?, n), do: n
  defp regex(<<?\\, _c, rest::binary>>, class?, n), do: regex(rest, class?, n + 2)
  defp regex("[" <> rest, _class?, n), do: regex(rest, true, n + 1)
  defp regex("]" <> rest, _class?, n), do: regex(rest, false, n + 1)

  defp regex("/" <> rest, false, n) do
    n + 1 + ident_length(rest, 0)
  end

  defp regex(<<_, rest::binary>>, class?, n), do: regex(rest, class?, n + 1)

  defp until(binary, pattern) do
    case :binary.match(binary, pattern) do
      {at, _length} -> at
      :nomatch -> byte_size(binary)
    end
  end

  defp skip_bytes(binary, n), do: binary_part(binary, n, byte_size(binary) - n)

  defp split_at(binary, n), do: {binary_part(binary, 0, n), skip_bytes(binary, n)}

  # The number of leading bytes that continue an identifier.
  defp ident_length(<<c, rest::binary>>, n) when is_ident_char(c), do: ident_length(rest, n + 1)
  defp ident_length(_rest, n), do: n

  # A numeric literal: digits, a decimal point, and the letters of a radix
  # prefix, an exponent, or a BigInt suffix.
  defp number_length(<<?., rest::binary>>, n), do: number_length(rest, n + 1)

  defp number_length(<<c, rest::binary>>, n) when is_ident_char(c), do: number_length(rest, n + 1)

  defp number_length(_rest, n), do: n
end
