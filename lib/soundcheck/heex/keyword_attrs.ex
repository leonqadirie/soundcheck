defmodule Soundcheck.Heex.KeywordAttrs do
  @moduledoc false
  # Elements that template expressions render from keyword attributes, the
  # `Phoenix.HTML` style that predates HEEx attributes:
  #
  #     {link("Reload", to: "#", phx_click: "reload")}
  #     {tag(:span, id: "clock", phx_hook: "LocalTime")}
  #     <div {if @open, do: [phx_window_keyup: "keyup"], else: []}>
  #
  # Each keyword list with a `phx_*` key becomes one element. Its attrs carry
  # the names `Phoenix.HTML` renders, `phx_window_keyup` as
  # `phx-window-keyup`, and every attr spans the call that receives the list,
  # or the expression that holds it. The element's tag comes from the call:
  # `link` renders `a`, `tag(:span, ...)` and `content_tag(:span, ...)` render
  # `span`, form input helpers render `input`. Form input helpers take their
  # `id` from the form field, so their elements carry one.
  #
  # Only rules that read events and hooks use these elements; `Walker`
  # leaves them out.

  alias Soundcheck.Heex.Node
  alias Soundcheck.Span

  # `Phoenix.HTML.Form` helpers whose `id` defaults to the form field's.
  @input_helpers ~w(text_input textarea select multiple_select checkbox radio_button
                    number_input email_input password_input hidden_input search_input
                    telephone_input url_input date_input time_input datetime_local_input
                    range_input color_input file_input)a

  @doc "The keyword-attribute elements of every expression in `nodes`."
  @spec elements([Node.t()] | Node.t()) :: [Node.Element.t()]
  def elements(nodes), do: nodes |> node_elements([]) |> Enum.reverse()

  # Each walker prepends to `acc`; `elements/1` reverses once at the end.
  defp node_elements(nodes, acc) when is_list(nodes),
    do: Enum.reduce(nodes, acc, &node_elements/2)

  defp node_elements(%Node.Element{attrs: attrs, children: children}, acc) do
    acc = Enum.reduce(attrs, acc, &attr_elements/2)
    node_elements(children, acc)
  end

  defp node_elements(%Node.EexBlock{head: head, clauses: clauses}, acc) do
    acc = expression(head.ast, head.span, acc)
    Enum.reduce(clauses, acc, &node_elements(&1.children, &2))
  end

  defp node_elements(%Node.BodyExpr{ast: ast, span: span}, acc), do: expression(ast, span, acc)
  defp node_elements(%Node.Eex{ast: ast, span: span}, acc), do: expression(ast, span, acc)
  defp node_elements(_node, acc), do: acc

  defp attr_elements(%Node.Attr{value: {:expr, ast, _source, span}}, acc),
    do: expression(ast, span, acc)

  defp attr_elements(_attr, acc), do: acc

  defp expression({:error, _reason}, _span, acc), do: acc
  defp expression(ast, span, acc), do: collect(ast, span, acc)

  # A call's trailing keyword list renders on the call's element; a list
  # anywhere else renders on the element of the expression that holds it.
  defp collect({call, meta, args} = node, span, acc) when is_list(args) do
    {init, last} = split_last(args)

    case {name(node), keyword?(last)} do
      {name, true} when not is_nil(name) ->
        site = call_span(span.file, meta, name) || span
        acc = collect(init, span, acc)
        [element(last, tag(name, args), site, name in @input_helpers) | acc]

      _other ->
        collect(args, span, collect(call, span, acc))
    end
  end

  defp collect(list, span, acc) when is_list(list) do
    if keyword?(list),
      do: [element(list, nil, span, false) | acc],
      else: Enum.reduce(list, acc, &collect(&1, span, &2))
  end

  defp collect({left, right}, span, acc), do: collect(right, span, collect(left, span, acc))
  defp collect(_leaf, _span, acc), do: acc

  defp split_last(args) do
    case Enum.reverse(args) do
      [last | init] -> {Enum.reverse(init), last}
      [] -> {[], nil}
    end
  end

  # A non-empty list of `{atom, value}` pairs with at least one `phx_*` key.
  defp keyword?([_ | _] = list) do
    Enum.reduce_while(list, false, fn
      {key, _value}, phx? when is_atom(key) ->
        {:cont, phx? or String.starts_with?(Atom.to_string(key), "phx_")}

      _other, _phx? ->
        {:halt, false}
    end)
  end

  defp keyword?(_other), do: false

  defp name({name, _meta, _args}) when is_atom(name), do: name
  defp name({{:., _, [_module, name]}, _meta, _args}) when is_atom(name), do: name
  defp name(_call), do: nil

  defp call_span(file, meta, name) do
    if meta[:line] && meta[:column], do: Span.covering(file, meta, Atom.to_string(name))
  end

  defp tag(:link, _args), do: "a"
  defp tag(kind, [tag | _]) when kind in [:tag, :content_tag] and is_atom(tag), do: to_string(tag)
  defp tag(name, _args) when name in @input_helpers, do: "input"
  defp tag(_name, _args), do: nil

  defp element(keyword, tag, span, input?) do
    attrs = for {key, value} <- keyword, do: keyword_attr(key, value, span)
    implicit_id = if input?, do: [keyword_attr(:id, {:form_field, [], []}, span)], else: []

    %Node.Element{
      tag: tag || "element",
      kind: :html,
      span: span,
      open_span: span,
      attrs: implicit_id ++ attrs
    }
  end

  defp keyword_attr(key, value, span) do
    name = key |> Atom.to_string() |> String.replace("_", "-")

    value =
      if is_binary(value),
        do: {:string, value, ?", span},
        else: {:expr, value, Macro.to_string(value), span}

    %Node.Attr{name: name, value: value, span: span, name_span: nil}
  end
end
