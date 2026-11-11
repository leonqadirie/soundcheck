defmodule Soundcheck.Elixir.SigilsTest do
  use Soundcheck.HeexCase

  alias Soundcheck.Elixir.Sigils

  defp templates(source) do
    {:ok, ast} =
      Code.string_to_quoted(source, columns: true, token_metadata: true, emit_warnings: false)

    Sigils.templates(ast, source, "lib/demo.ex")
  end

  # Every element's open span and every attribute span in every template
  # must cover exactly the source text for that tag or attribute.
  defp assert_spans_match(source) do
    for template <- templates(source), element <- elements(template.root) do
      assert String.starts_with?(text_at(source, element.open_span), "<" <> element.tag)

      for %Node.Attr{name: name, name_span: name_span} <- element.attrs, is_binary(name) do
        assert text_at(source, name_span) == name
      end
    end
  end

  test "maps heredoc sigils, shifting columns by the indentation" do
    source = ~S'''
    defmodule Demo do
      use Phoenix.Component

      def card(assigns) do
        ~H"""
        <div class="card" phx-click="open">
          <p>{@title}</p>
        </div>
        """
      end
    end
    '''

    [template] = templates(source)
    div = element(template.root, "div")

    assert div.span.start == {6, 5}
    assert text_at(source, attr(div, "phx-click").span) == ~S(phx-click="open")
    assert_spans_match(source)
  end

  test "maps single-line sigils for each delimiter" do
    source = ~S"""
    defmodule Demo do
      def a(assigns), do: ~H"<b id='a'></b>"
      def b(assigns), do: ~H'<b id="b"></b>'
      def c(assigns), do: ~H(<b id="c"></b>)
      def d(assigns), do: ~H[<b id="d"></b>]
      def e(assigns), do: ~H|<b id="e"></b>|
      def f(assigns), do: ~H/<b id="f"><\/b>/
    end
    """

    assert [_, _, _, _, _, _] = templates(source)
    assert_spans_match(source)
  end

  test "maps sigils on lines with multibyte text before them" do
    source = ~S"""
    defmodule Demo do
      def a(assigns), do: {"Grüße", ~H'<b id="x"></b>'}
    end
    """

    [template] = templates(source)
    b = element(template.root, "b")
    assert text_at(source, attr(b, "id").span) == ~S(id="x")
  end

  test "accounts for escaped closing delimiters" do
    source = ~S"""
    defmodule Demo do
      def a(assigns), do: ~H"<b id=\"x\" class=\"y\"></b>"
    end
    """

    [template] = templates(source)
    b = element(template.root, "b")

    assert {:string, "x", ?", _} = attr(b, "id").value
    assert text_at(source, attr(b, "class").name_span) == "class"
  end

  test "maps multi-line expressions inside heredocs" do
    source = ~S'''
    defmodule Demo do
      def a(assigns) do
        ~H"""
        <p>{foo(1,
             @x)}</p>
        """
      end
    end
    '''

    [template] = templates(source)
    [%Node.BodyExpr{ast: {:foo, _, [1, {:@, x_meta, _}]}}] = element(template.root, "p").children

    assert {x_meta[:line], x_meta[:column]} == {5, 10}
    assert text_at(source, Soundcheck.Span.new("x", {5, 10}, {5, 12})) == "@x"
  end

  test "records the owning module and function" do
    source = ~S'''
    defmodule MyAppWeb.PostLive.Index do
      def render(assigns) when is_map(assigns) do
        ~H"<p></p>"
      end

      defmodule Row do
        defp row(assigns), do: ~H"<tr></tr>"
      end

      defmodule __MODULE__.Cell do
        defp cell(assigns), do: ~H"<td></td>"
      end
    end

    defmodule unquote(name) do
      def x(assigns), do: ~H"<i></i>"
    end
    '''

    owners = Enum.map(templates(source), & &1.owner)

    assert owners == [
             {MyAppWeb.PostLive.Index, :render},
             {MyAppWeb.PostLive.Index.Row, :row},
             {MyAppWeb.PostLive.Index.Cell, :cell},
             nil
           ]
  end

  test "marks templates as sigils" do
    [template] = templates(~S|defmodule D do def a(assigns), do: ~H"<p></p>" end|)
    assert template.origin == :sigil
    assert template.file == "lib/demo.ex"
  end
end
