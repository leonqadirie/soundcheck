defmodule Soundcheck.Heex.ParserTest do
  use Soundcheck.HeexCase

  describe "elements" do
    test "classifies tags, components, and slots" do
      %{root: root, errors: []} =
        Parser.parse(~S"""
        <div><.button /><MyAppWeb.Components.card><:title>t</:title></MyAppWeb.Components.card></div>
        """)

      kinds = for element <- elements(root), do: {element.tag, element.kind}

      assert kinds == [
               {"div", :html},
               {".button", :local_component},
               {"MyAppWeb.Components.card", :remote_component},
               {":title", :slot}
             ]
    end

    test "records how each element closed" do
      %{root: root, errors: []} = Parser.parse("<p><br><img src=\"x\"><.icon /></p>")

      assert element(root, "p").close == :normal
      assert element(root, "br").close == :void
      assert element(root, "img").close == :void
      assert element(root, ".icon").close == :self
    end

    test "nests children" do
      %{root: [ul]} = Parser.parse("<ul><li>a</li><li>b</li></ul>")
      assert [%Node.Element{tag: "li"}, %Node.Element{tag: "li"}] = ul.children
    end
  end

  describe "attributes" do
    test "parses string, expression, bare, and root attributes" do
      source = ~S|<input type="text" value='v' disabled phx-change={JS.push("x")} {@rest} />|
      %{root: [input], errors: []} = Parser.parse(source)

      assert {:string, "text", ?", _} = attr(input, "type").value
      assert {:string, "v", ?', _} = attr(input, "value").value
      assert attr(input, "disabled").value == nil

      assert {:expr, {{:., _, [{:__aliases__, _, [:JS]}, :push]}, _, ["x"]}, ~S|JS.push("x")|, _} =
               attr(input, "phx-change").value

      assert {:expr, {:@, _, [{:rest, _, nil}]}, "@rest", _} = attr(input, :root).value
    end

    test "attribute and value spans cover their source text" do
      source = ~S(<a href={~p"/posts/#{@post}"} class="btn">x</a>)
      %{root: [a]} = Parser.parse(source)

      href = attr(a, "href")
      assert text_at(source, href.span) == ~S(href={~p"/posts/#{@post}"})
      assert text_at(source, href.name_span) == "href"
      {:expr, _ast, _source, expr_span} = href.value
      assert text_at(source, expr_span) == ~S(~p"/posts/#{@post}")

      {:string, _value, _delimiter, value_span} = attr(a, "class").value
      assert text_at(source, value_span) == "btn"
    end
  end

  describe "expressions" do
    test "balanced braces, interpolation, and escaped braces stay inside the expression" do
      cases = [
        ~S|{"a #{inspect(%{b: 1})} c"}|,
        ~S|{%{a: %{b: 1}}}|,
        ~S|{"\}"}|,
        ~S|{"\{"}|,
        ~S|{~s({})}|,
        ~S|{@valid?}|
      ]

      for source <- cases do
        %{root: [%Node.BodyExpr{} = expr], errors: errors} = Parser.parse(source)
        assert errors == [], "unexpected errors for #{source}: #{inspect(errors)}"
        refute match?({:error, _}, expr.ast), "expression failed to parse in #{source}"
        assert "{" <> expr.source <> "}" == source
      end
    end

    test "counts braces inside strings, as LiveView does" do
      # LiveView ends this expression at the first `}`; the template does
      # not compile there either.
      %{root: [%Node.BodyExpr{source: ~S|"|} | _]} = Parser.parse(~S|{"}"}|)
    end

    test "keeps the node when an expression does not parse" do
      %{root: [%Node.BodyExpr{ast: {:error, _}, source: "1 +"}], errors: []} =
        Parser.parse("{1 +}")
    end

    test "expression ASTs carry file positions, including later lines" do
      source = "<p>\n  {foo(1,\n     @x)}\n</p>"
      %{root: [p]} = Parser.parse(source)

      [%Node.Text{}, %Node.BodyExpr{ast: {:foo, meta, [1, {:@, x_meta, _}]}}, %Node.Text{}] =
        p.children

      assert {meta[:line], meta[:column]} == {2, 4}
      assert {x_meta[:line], x_meta[:column]} == {3, 6}
    end
  end

  describe "EEx" do
    test "groups if/else/end into a block with clauses" do
      source = "<%= if @x do %><p>a</p><% else %><p>b</p><% end %>"
      %{root: [block], errors: []} = Parser.parse(source)

      assert %Node.EexBlock{marker: "=", close: :normal} = block
      assert {:if, _, [{:@, _, [{:x, _, nil}]}, [do: {:__block__, _, []}]]} = block.head.ast
      assert [%{source: " if @x do "}, %{source: " else "}] = block.clauses

      assert [[%Node.Element{tag: "p"}], [%Node.Element{tag: "p"}]] =
               Enum.map(block.clauses, & &1.children)
    end

    test "parses middle clause heads without their arrow" do
      source = "<%= cond do %><% @ready? -> %>a<% x when x > @max -> %>b<% true -> %>c<% end %>"
      %{root: [block], errors: []} = Parser.parse(source)

      assert [
               %{ast: nil},
               %{ast: {:@, _, [{:ready?, _, _}]}},
               %{ast: {:when, _, _}},
               %{ast: true}
             ] =
               block.clauses
    end

    test "groups case clauses" do
      source = """
      <%= case @result do %>
        <% {:ok, value} -> %>{value}
        <% {:error, _} -> %>failed
      <% end %>
      """

      %{root: [block | _], errors: []} = Parser.parse(source)
      assert [_head, _ok, _error] = block.clauses
    end

    test "parses for comprehensions and standalone expressions" do
      source = "<%= for x <- @xs do %><%= x %><% end %><% y = 1 %>"
      %{root: [block, assign], errors: []} = Parser.parse(source)

      assert {:for, _, _} = block.head.ast
      assert [%{children: [%Node.Eex{marker: "=", ast: {:x, _, nil}}]}] = block.clauses
      assert %Node.Eex{marker: "", ast: {:=, _, _}} = assign
    end

    test "parses a head that opens a call closed by `end)`" do
      source = "<%= Enum.map(@xs, fn x -> %><p><%= x %></p><% end) %>"
      %{root: [block], errors: []} = Parser.parse(source)

      assert {{:., _, [{:__aliases__, _, [:Enum]}, :map]}, _,
              [{:@, _, [{:xs, _, nil}]}, {:fn, _, _}]} =
               block.head.ast
    end

    test "parses the head of a block left open at the end of input" do
      %{root: [block], errors: [_unclosed]} = Parser.parse("<%= for x <- @xs do %><%= x %>")

      assert %Node.EexBlock{close: :missing} = block
      assert {:for, _, _} = block.head.ast
    end

    test "parses comments" do
      %{root: nodes, errors: []} = Parser.parse("<!-- html --><%!-- eex --%><%# old %>")
      assert [:html, :eex, :eex] = Enum.map(nodes, & &1.kind)
    end
  end

  describe "raw text" do
    test "treats script and style bodies as text" do
      source = "<script>const x = {a: 1}; if (a < b) {}</script><style>p { color: red }</style>"
      %{root: [script, style], errors: []} = Parser.parse(source)

      assert [%Node.Text{value: "const x = {a: 1}; if (a < b) {}"}] = script.children
      assert [%Node.Text{value: "p { color: red }"}] = style.children
    end

    test "phx-no-curly-interpolation turns braces into text for the subtree" do
      source = "<div phx-no-curly-interpolation><p>{x}</p></div><p>{y}</p>"
      %{root: [div, p], errors: []} = Parser.parse(source)

      refute Enum.any?(nodes(div.children), &match?(%Node.BodyExpr{}, &1))
      assert [%Node.BodyExpr{source: "y"}] = p.children
    end
  end

  describe "error recovery" do
    test "closes an element left open at the end of input" do
      %{root: [div], errors: errors} = Parser.parse("<div><p>text")

      assert div.close == :missing
      assert [%Node.Element{tag: "p", close: :missing}] = div.children
      assert Enum.map(errors, & &1.message) == ["unclosed tag `<p>`", "unclosed tag `<div>`"]
    end

    test "closes inner elements at an outer closing tag" do
      %{root: [div, p], errors: [error]} = Parser.parse("<div><span>a</div><p>b</p>")

      assert div.close == :normal
      assert p.close == :normal
      assert [%Node.Element{tag: "span", close: :missing}] = div.children
      assert error.message == "unclosed tag `<span>`"
    end

    test "drops a closing tag with no open element" do
      %{root: [p], errors: [error]} = Parser.parse("<p>a</p></div>")
      assert p.close == :normal
      assert error.message == "unmatched closing tag `</div>`"
    end

    test "closes elements left open inside an EEx clause" do
      %{root: [block], errors: [error]} = Parser.parse("<%= if @x do %><p>a<% end %>")
      assert [%{children: [%Node.Element{tag: "p", close: :missing}]}] = block.clauses
      assert error.message == "unclosed tag `<p>`"
    end

    test "drops an EEx end outside a block" do
      %{root: [p], errors: [error]} = Parser.parse("<p>a</p><% end %>")
      assert p.tag == "p"
      assert error.message =~ "outside a block"
    end

    test "reports an unclosed expression and keeps preceding nodes" do
      %{root: [p], errors: [error]} = Parser.parse("<p>a</p>{@x")
      assert p.tag == "p"
      assert error.message == "unclosed `{` expression"
    end

    test "reports an unclosed tag at the end of input" do
      %{root: [input], errors: errors} = Parser.parse(~S(<input type="text"))
      assert input.tag == "input"
      assert Enum.any?(errors, &(&1.message == "unclosed tag `<input`"))
    end
  end

  describe "positions" do
    test "columns count codepoints, not bytes" do
      source = "<p>Grüße</p><a id=\"x\">é</a>"
      %{root: [_p, a]} = Parser.parse(source)

      assert a.span.start == {1, 13}
      assert text_at(source, a.span) == "<a id=\"x\">é</a>"
    end

    test "every element span covers its source text" do
      source = """
      <div class="a">
        <.link navigate={~p"/"}>Home</.link>
        <ul>
          <li :for={x <- @xs}>{x}</li>
        </ul>
      </div>
      """

      %{root: root, errors: []} = Parser.parse(source, file: "a.heex")

      for element <- elements(root) do
        text = text_at(source, element.span)
        assert String.starts_with?(text, "<" <> element.tag)
        assert String.ends_with?(text, "</#{element.tag}>")
      end
    end

    test "template id is the file and its first position" do
      template = Parser.parse("<p></p>", file: "lib/a.html.heex")
      assert template.id == {"lib/a.html.heex", {1, 1}}
      assert template.origin == :file
    end
  end
end
