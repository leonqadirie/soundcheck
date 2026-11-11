defmodule Soundcheck.JS.LexerTest do
  use ExUnit.Case, async: true

  alias Soundcheck.JS.Lexer

  defp kinds(source), do: for({kind, value, _, _} <- Lexer.tokenize(source), do: {kind, value})

  test "skips comments and whitespace" do
    assert kinds("a // b\n/* c */ d") == [{:ident, "a"}, {:ident, "d"}]
  end

  test "resolves escapes in strings" do
    assert [{:string, ~S|it's "q"|}] = kinds(~S|'it\'s "q"'|)
  end

  test "marks template literals with substitutions as dynamic" do
    assert [{:template, "plain"}] = kinds("`plain`")
    assert [{:template, :dynamic}] = kinds("`row-${id}`")
    assert [{:template, :dynamic}, {:ident, "x"}] = kinds("`a ${ {b: `}`} }` x")
  end

  test "tells regex literals from division" do
    assert [{:ident, "a"}, {:punct, "/"}, {:ident, "b"}, {:punct, "/"}, {:ident, "c"}] =
             kinds("a / b / c")

    assert [{:ident, "x"}, {:punct, "="}, {:regex, nil}, {:punct, ";"}, {:ident, "y"}] =
             kinds("x = /}\\/{[/]/g; y")

    assert [{:ident, "return"}, {:regex, nil}] = kinds("return /a/")
    assert [{:punct, ")"}, {:punct, "/"}, {:number, nil}] = kinds(") / 2")
  end

  test "reads multi-character operators" do
    assert [{:ident, "a"}, {:punct, "==="}, {:ident, "b"}, {:punct, "=>"}, {:punct, "..."}] =
             kinds("a === b => ...")
  end

  test "reads a byte that is not valid UTF-8 as a one-byte token" do
    assert [{:ident, "a", 0, 1}, {:punct, <<0xFF>>, 1, 2}, {:ident, "b", 2, 3}] =
             Lexer.tokenize(<<"a", 0xFF, "b">>)
  end

  test "records byte offsets" do
    assert [{:ident, "ab", 0, 2}, {:string, "c", 3, 6}] = Lexer.tokenize(~S|ab "c"|)
  end

  test "never raises on unterminated input" do
    for source <- [~S|"abc|, "`abc ${", "/* abc", "/abc"] do
      assert is_list(Lexer.tokenize(source))
    end
  end
end
