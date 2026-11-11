defmodule Soundcheck.Analysis.Guards do
  @moduledoc false
  # The `:if` guards around a template location, and whether a component
  # call site rules them out.
  #
  # A guard is `{key, :truthy | :falsy}`: an `:if` on an enclosing element
  # reads a bare `@key`, its negation (`!@key`, `not @key`), or a conjunction
  # of those (`&&`, `and`). Other `:if` expressions yield no guard.
  #
  # A call site rules a guard out when it passes `key` as a literal of the
  # opposite truthiness (`filtering_enabled?={false}`), or omits it and the
  # function component declares a literal default of the opposite
  # truthiness. A call site that spreads attributes (`{@rest}`) before
  # passing `key`, or without passing it, rules out nothing.
  #
  # `conditions/2` lists every condition around a location, guards or not,
  # and `holds?/3` tells whether a call site proves all of them.

  alias Soundcheck.Analysis.Components
  alias Soundcheck.Beam.Introspect
  alias Soundcheck.Heex.Node
  alias Soundcheck.Span

  @type guard :: {atom(), :truthy | :falsy}

  @typedoc """
  One condition around a location: an `:if` that reads only guards, or
  `:opaque` for any other `:if` and for `if`, `unless`, `case`, and `cond`
  EEx blocks.
  """
  @type condition :: {:guards, [guard()]} | :opaque

  @eex_conditionals [:if, :unless, :case, :cond]

  @doc "The guards of every element in `nodes` that encloses `span`."
  @spec at([Node.t()], Span.t()) :: [guard()]
  def at(nodes, %Span{start: start}) when is_list(nodes), do: around(nodes, start)

  defp around(nodes, position), do: Enum.flat_map(nodes, &enclosing(&1, position))

  defp enclosing(%Node.Element{span: span, attrs: attrs, children: children}, position) do
    if Span.contains?(span, position),
      do: Enum.flat_map(attrs, &attr_guards/1) ++ around(children, position),
      else: []
  end

  defp enclosing(%Node.EexBlock{clauses: clauses}, position),
    do: Enum.flat_map(clauses, &around(&1.children, position))

  defp enclosing(_node, _position), do: []

  defp attr_guards(%Node.Attr{name: ":if", value: {:expr, ast, _source, _span}}),
    do: guards(ast, :truthy, [])

  defp attr_guards(_attr), do: []

  @doc "Every condition in `nodes` that encloses `span`, outermost first."
  @spec conditions([Node.t()], Span.t()) :: [condition()]
  def conditions(nodes, %Span{start: start}) when is_list(nodes),
    do: conditions_around(nodes, start)

  defp conditions_around(nodes, position),
    do: Enum.flat_map(nodes, &enclosing_conditions(&1, position))

  defp enclosing_conditions(%Node.Element{span: span} = element, position) do
    if Span.contains?(span, position),
      do:
        Enum.flat_map(element.attrs, &attr_condition/1) ++
          conditions_around(element.children, position),
      else: []
  end

  defp enclosing_conditions(%Node.EexBlock{span: span, head: head, clauses: clauses}, position) do
    if Span.contains?(span, position) do
      inner = Enum.flat_map(clauses, &conditions_around(&1.children, position))
      if eex_conditional?(head.ast), do: [:opaque | inner], else: inner
    else
      []
    end
  end

  defp enclosing_conditions(_node, _position), do: []

  defp attr_condition(%Node.Attr{name: ":if", value: {:expr, ast, _source, _span}}) do
    case full_guards(ast, :truthy) do
      {:ok, guards} -> [{:guards, guards}]
      :error -> [:opaque]
    end
  end

  defp attr_condition(%Node.Attr{name: ":if"}), do: [:opaque]
  defp attr_condition(_attr), do: []

  defp eex_conditional?({kind, _, _}) when kind in @eex_conditionals, do: true
  defp eex_conditional?(_ast), do: false

  # Like `guards/3`, but fails unless the whole expression reads guards.
  defp full_guards({:@, _, [{key, _, context}]}, want) when is_atom(key) and is_atom(context),
    do: {:ok, [{key, want}]}

  defp full_guards({negation, _, [operand]}, want) when negation in [:!, :not],
    do: full_guards(operand, flip(want))

  defp full_guards({conjunction, _, [left, right]}, :truthy) when conjunction in [:&&, :and] do
    with {:ok, left} <- full_guards(left, :truthy),
         {:ok, right} <- full_guards(right, :truthy),
         do: {:ok, left ++ right}
  end

  defp full_guards(_ast, _want), do: :error

  @doc """
  Whether the call site `element` of `callee` proves every one of
  `conditions`: each reads only guards, and the call site passes, or
  defaults, a value of the wanted truthiness for each.
  """
  @spec holds?([condition()], Node.Element.t(), Components.callee()) :: boolean()
  def holds?(conditions, %Node.Element{} = element, callee) do
    Enum.all?(conditions, fn
      {:guards, guards} ->
        Enum.all?(guards, fn {key, want} ->
          value(element, key, callee) == {:known, want == :truthy}
        end)

      :opaque ->
        false
    end)
  end

  defp guards({:@, _, [{key, _, context}]}, want, acc) when is_atom(key) and is_atom(context),
    do: [{key, want} | acc]

  defp guards({negation, _, [operand]}, want, acc) when negation in [:!, :not],
    do: guards(operand, flip(want), acc)

  defp guards({conjunction, _, [left, right]}, :truthy, acc) when conjunction in [:&&, :and],
    do: guards(right, :truthy, guards(left, :truthy, acc))

  defp guards(_ast, _want, acc), do: acc

  defp flip(:truthy), do: :falsy
  defp flip(:falsy), do: :truthy

  @doc """
  Whether the call site `element` of `callee` fails one of `guards`, so the
  guarded content never renders from it.
  """
  @spec excluded?([guard()], Node.Element.t(), Components.callee()) :: boolean()
  def excluded?(guards, %Node.Element{} = element, callee) do
    Enum.any?(guards, fn {key, want} ->
      case value(element, key, callee) do
        {:known, truthy?} -> truthy? != (want == :truthy)
        :unknown -> false
      end
    end)
  end

  # A spread (`{@rest}`) before the attr may set it, so it reads as unknown.
  defp value(%Node.Element{attrs: attrs}, key, callee) do
    name = Atom.to_string(key)

    case Enum.find(attrs, &(&1.name in [name, :root])) do
      %Node.Attr{name: :root} ->
        :unknown

      %Node.Attr{value: {:expr, literal, _source, _span}} when literal in [true, false, nil] ->
        {:known, truthy?(literal)}

      %Node.Attr{value: {:string, _value, _delimiter, _span}} ->
        {:known, true}

      # A bare attribute (`<.tile feature_toggle?>`) passes `true`.
      %Node.Attr{value: nil} ->
        {:known, true}

      %Node.Attr{} ->
        :unknown

      nil ->
        default(callee, key)
    end
  end

  defp default({:function, module, fun}, key) do
    with {:ok, %{^fun => %{attrs: attrs}}} <- Introspect.components(module),
         %{opts: opts} <- Enum.find(attrs, &(&1.name == key)),
         {:ok, default} <- Keyword.fetch(opts, :default),
         true <- literal?(default) do
      {:known, truthy?(default)}
    else
      _unknown -> :unknown
    end
  end

  defp default(_callee, _key), do: :unknown

  defp literal?(value), do: is_atom(value) or is_binary(value) or is_number(value)

  defp truthy?(value), do: value not in [false, nil]
end
