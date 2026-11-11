defmodule Soundcheck.Heex.DifferentialTest do
  @moduledoc """
  Compares soundcheck's HEEx parser with LiveView's private
  `Phoenix.LiveView.TagEngine.Parser` on every template LiveView accepts.

  Both trees are normalized to the same shape: elements with their full tag
  names, attributes with their values, body expressions, and EEx
  expressions and blocks. Text and comments are dropped, because LiveView
  folds HTML comments into text and prunes whitespace. Positions are
  compared for `.heex` files and heredoc sigils; LiveView assumes every
  `~H` is a heredoc, so single-line sigils compare structure only.

  Template sources:

    * the cases below;
    * every `~H` sigil in LiveView's own `lib/`;
    * every `.heex` file and `~H` sigil under the directories listed in
      the `SOUNDCHECK_DIFF_PATHS` environment variable (colon-separated),
      for running against real applications.
  """

  use ExUnit.Case, async: true

  alias Phoenix.LiveView.TagEngine.Parser, as: LiveViewParser
  alias Soundcheck.Elixir.Sigils
  alias Soundcheck.Heex.Node
  alias Soundcheck.Heex.OffsetMap
  alias Soundcheck.Heex.Parser

  @cases [
    ~S(<div id="a" class={@cls} {@rest} disabled></div>),
    ~S(<.button phx-click="save" type="submit">Save {@n}</.button>),
    ~S(<MyAppWeb.CoreComponents.modal id="m" show><:title>T</:title>Body</MyAppWeb.CoreComponents.modal>),
    ~S(<.table rows={@rows}><:col :let={row} label="Name">{row.name}</:col></.table>),
    ~S(<ul><li :for={item <- @items} :key={item.id}>{item.name}</li></ul>),
    ~S(<p :if={@show}>shown</p><br><img src="x"><input type="text" />),
    ~S(<%= if @x do %><p>a</p><% else %><p>b</p><% end %>),
    ~S(<%= for x <- @xs do %><i>{x}</i><% end %><% y = 1 %><%= y %>),
    ~S(<%= case @r do %><% {:ok, v} -> %>{v}<% {:error, _} -> %>err<% end %>),
    ~S|<a href={~p"/posts/#{@post}"} phx-click={JS.push("x", value: %{id: 1})}>x</a>|,
    ~S|<div>{"\}"} {%{a: %{b: 1}}} {"#{x}"} {@valid?}</div>|,
    ~S(<script>const x = {a: 1};</script><style>p { color: red }</style>),
    ~S(<div phx-no-curly-interpolation><p>{x}</p></div>),
    ~S(<!-- html --><%!-- eex --%><p>after</p>),
    ~s(<div\n  class="multi"\n  phx-click="go"\n>\n  {@x}\n</div>)
  ]

  test "agrees with LiveView's parser on the curated cases" do
    mismatches = for source <- @cases, mismatch <- compare(source, []), do: mismatch
    assert mismatches == []
  end

  test "agrees with LiveView's parser on LiveView's own sigils" do
    lib = Path.join(Mix.Project.deps_paths()[:phoenix_live_view], "lib")
    {checked, mismatches} = compare_paths([lib])

    assert checked > 0
    assert mismatches == []
  end

  @tag timeout: :infinity
  test "agrees with LiveView's parser on SOUNDCHECK_DIFF_PATHS" do
    case System.get_env("SOUNDCHECK_DIFF_PATHS") do
      nil ->
        :ok

      paths ->
        {checked, mismatches} = compare_paths(String.split(paths, ":", trim: true))
        IO.puts("\ndifferential: compared #{checked} templates")
        assert mismatches == []
    end
  end

  # ── Sources ──

  defp compare_paths(dirs) do
    results =
      for dir <- dirs,
          file <- Path.wildcard(Path.join(dir, "**/*.{ex,heex}")),
          not vendored?(Path.relative_to(file, dir)),
          template <- templates_in(file) do
        compare_template(template)
      end

    {Enum.count(results, &(&1 != :skipped)),
     results |> Enum.reject(&(&1 == :skipped)) |> List.flatten()}
  end

  # Skips dependency, build, and asset trees below a scanned directory; the
  # directory itself may live under `deps/`, as LiveView's own `lib/` does.
  defp vendored?(relative),
    do:
      String.starts_with?(relative, ["deps/", "_build/"]) or
        relative =~ ~r{(^|/)(node_modules|deps|_build)/}

  defp templates_in(file) do
    source = File.read!(file)

    if String.ends_with?(file, ".heex") do
      [%{file: file, body: source, lv_opts: [], map: OffsetMap.identity(), positions?: true}]
    else
      sigils_in(file, source)
    end
  end

  defp sigils_in(file, source) do
    case Code.string_to_quoted(source, columns: true, token_metadata: true, emit_warnings: false) do
      {:ok, ast} ->
        for sigil <- Sigils.find(ast) do
          heredoc? = sigil.meta[:delimiter] in [~s("""), "'''"]

          %{
            file: file,
            body: sigil.body,
            lv_opts: [
              line: sigil.meta[:line] + 1,
              indentation: sigil.body_meta[:indentation] || 0
            ],
            map: OffsetMap.for_sigil(sigil.meta, sigil.body_meta, source),
            positions?: heredoc?
          }
        end

      {:error, _reason} ->
        []
    end
  end

  # ── Comparison ──

  defp compare(source, lv_opts) do
    case compare_template(%{
           file: "nofile",
           body: source,
           lv_opts: lv_opts,
           map: OffsetMap.identity(),
           positions?: true
         }) do
      :skipped -> flunk("LiveView rejected curated case:\n#{source}")
      mismatches -> mismatches
    end
  end

  defp compare_template(%{body: body, file: file} = template) do
    lv_opts =
      [
        tag_handler: Phoenix.LiveView.HTMLEngine,
        file: file,
        skip_macro_components: true,
        prune_text_after_slots: false
      ] ++ template.lv_opts

    case LiveViewParser.parse(body, lv_opts) do
      {:ok, %{nodes: lv_nodes}} ->
        ours = Parser.parse(body, file: file, offset_map: template.map)
        positions? = template.positions?

        expected = normalize_lv(lv_nodes, positions?)
        actual = normalize_ours(ours.root, positions?)

        cond do
          ours.errors != [] ->
            [{file, :errors, Enum.map(ours.errors, &{&1.message, &1.span.start})}]

          expected != actual ->
            [{file, :tree, first_difference(expected, actual)}]

          true ->
            []
        end

      {:error, _line, _column, _message} ->
        :skipped
    end
  end

  defp first_difference(expected, actual) do
    expected
    |> Enum.zip(actual)
    |> Enum.find(fn {e, a} -> e != a end)
    |> Kernel.||({:length, length(expected), length(actual)})
  end

  # ── Normalization ──
  #
  # Shapes:
  #   {:el, tag, attrs, children, position}
  #   {:attr, name, value, position}         value: {:string, v} | {:expr, code} | nil
  #   {:body_expr, code, position}
  #   {:eex, code}
  #   {:block, head, [children], [middle_codes]}

  defp normalize_lv(nodes, positions?), do: Enum.flat_map(nodes, &lv_node(&1, positions?))

  defp lv_node({:block, _type, _name, attrs, children, meta, _close}, p),
    do: [{:el, meta.tag_name, lv_attrs(attrs, p), normalize_lv(children, p), pos(meta, p)}]

  defp lv_node({:self_close, _type, _name, attrs, meta}, p),
    do: [{:el, meta.tag_name, lv_attrs(attrs, p), [], pos(meta, p)}]

  defp lv_node({:body_expr, code, meta}, p), do: [{:body_expr, code, pos(meta, p)}]
  defp lv_node({:eex, code, _meta}, _p), do: [{:eex, String.trim(code)}]

  defp lv_node({:eex_block, head, clauses, _meta}, p) do
    children = for {nodes, _marker, _meta} <- clauses, do: normalize_lv(nodes, p)
    middles = for {_nodes, marker, _meta} <- Enum.drop(clauses, -1), do: String.trim(marker)
    [{:block, String.trim(head), children, middles}]
  end

  defp lv_node(_text_or_comment, _p), do: []

  defp lv_attrs(attrs, p) do
    for {name, value, meta} <- attrs do
      {:attr, name, lv_value(value), pos(meta, p)}
    end
  end

  defp lv_value({:string, value, _meta}), do: {:string, value}
  defp lv_value({:expr, code, _meta}), do: {:expr, code}
  defp lv_value(nil), do: nil

  defp normalize_ours(nodes, positions?), do: Enum.flat_map(nodes, &our_node(&1, positions?))

  defp our_node(%Node.Element{} = element, p) do
    children = normalize_ours(element.children, p)
    [{:el, element.tag, our_attrs(element.attrs, p), children, span_pos(element.span, p)}]
  end

  defp our_node(%Node.BodyExpr{source: source, span: span}, p),
    do: [{:body_expr, source, span_pos(span, p)}]

  defp our_node(%Node.Eex{source: source}, _p), do: [{:eex, String.trim(source)}]

  defp our_node(%Node.EexBlock{head: head, clauses: clauses}, p) do
    children = for clause <- clauses, do: normalize_ours(clause.children, p)
    middles = for clause <- Enum.drop(clauses, 1), do: String.trim(clause.source)
    [{:block, String.trim(head.source), children, middles}]
  end

  defp our_node(_text_or_comment, _p), do: []

  defp our_attrs(attrs, p) do
    for %Node.Attr{} = attr <- attrs do
      {:attr, attr.name, our_value(attr.value), attr_pos(attr, p)}
    end
  end

  defp our_value({:string, value, _delimiter, _span}), do: {:string, value}
  defp our_value({:expr, _ast, source, _span}), do: {:expr, source}
  defp our_value(nil), do: nil

  # LiveView anchors a root attribute (`{@rest}`) at its expression and a
  # named attribute at its name.
  defp attr_pos(%Node.Attr{name: :root, value: {:expr, _ast, _source, span}}, p),
    do: span_pos(span, p)

  defp attr_pos(%Node.Attr{name_span: span}, p), do: span_pos(span, p)

  defp pos(meta, true), do: {meta[:line], meta[:column]}
  defp pos(_meta, false), do: nil

  defp span_pos(span, true), do: span.start
  defp span_pos(_span, false), do: nil
end
