defmodule Soundcheck.Heex.Reads do
  @moduledoc false
  # Finds `@assign` reads in a parsed template: in body expressions,
  # attribute expressions, EEx expressions, and EEx block and middle clause
  # heads, in source order. Expressions that did not parse contribute
  # nothing.

  alias Soundcheck.Heex.Node
  alias Soundcheck.Heex.Template
  alias Soundcheck.Span

  defmodule Read do
    @moduledoc false
    # One `@key` read. The span covers `@` and the key.
    @enforce_keys [:key, :span]
    defstruct [:key, :span]

    @type t :: %__MODULE__{key: atom(), span: Span.t()}
  end

  @type read :: Read.t()

  @spec assigns(Template.t()) :: [read()]
  def assigns(%Template{file: file} = template),
    do: template |> expressions() |> Enum.flat_map(&reads_in(&1, file))

  @doc "Every parsed expression AST in the template, in source order."
  @spec expressions(Template.t()) :: [Macro.t()]
  def expressions(%Template{root: root}), do: node_expressions(root)

  @doc "Every parsed expression AST in `nodes` and their descendants, in source order."
  @spec node_expressions([Node.t()]) :: [Macro.t()]
  def node_expressions(nodes) do
    nodes
    |> expressions([])
    |> Enum.reverse()
    |> Enum.reject(&match?({:error, _reason}, &1))
  end

  @doc """
  The `@assign` reads that run on every render: reads inside an element
  with `:if` (other than the condition itself), inside an EEx block's
  clauses, or inside a slot are left out, because they run only on some
  renders.
  """
  @spec unconditional(Template.t()) :: [read()]
  def unconditional(%Template{root: root, file: file}) do
    root
    |> unconditional_expressions([])
    |> Enum.reverse()
    |> Enum.flat_map(&reads_in(&1, file))
  end

  defp unconditional_expressions(nodes, acc) when is_list(nodes),
    do: Enum.reduce(nodes, acc, &unconditional_expressions/2)

  defp unconditional_expressions(%Node.Element{kind: :slot}, acc), do: acc

  defp unconditional_expressions(%Node.Element{attrs: attrs, children: children}, acc) do
    case Enum.find(attrs, &(&1.name == ":if")) do
      %Node.Attr{value: {:expr, condition, _source, _span}} ->
        [condition | acc]

      _unconditional ->
        children |> unconditional_expressions(Enum.reduce(attrs, acc, &attr_expression/2))
    end
  end

  defp unconditional_expressions(%Node.BodyExpr{ast: ast}, acc), do: [ast | acc]
  defp unconditional_expressions(%Node.Eex{ast: ast}, acc), do: [ast | acc]
  defp unconditional_expressions(%Node.EexBlock{head: head}, acc), do: [head.ast | acc]
  defp unconditional_expressions(_text_or_comment, acc), do: acc

  defp expressions(nodes, acc) when is_list(nodes), do: Enum.reduce(nodes, acc, &expressions/2)

  defp expressions(%Node.Element{attrs: attrs, children: children}, acc) do
    acc = Enum.reduce(attrs, acc, &attr_expression/2)
    expressions(children, acc)
  end

  defp expressions(%Node.BodyExpr{ast: ast}, acc), do: [ast | acc]
  defp expressions(%Node.Eex{ast: ast}, acc), do: [ast | acc]

  defp expressions(%Node.EexBlock{head: head, clauses: clauses}, acc) do
    Enum.reduce(clauses, [head.ast | acc], fn clause, acc ->
      acc = if clause.ast, do: [clause.ast | acc], else: acc
      expressions(clause.children, acc)
    end)
  end

  defp expressions(_text_or_comment, acc), do: acc

  defp attr_expression(%Node.Attr{value: {:expr, ast, _source, _span}}, acc), do: [ast | acc]
  defp attr_expression(%Node.Attr{}, acc), do: acc

  defp reads_in({:error, _reason}, _file), do: []

  defp reads_in(ast, file) do
    for {:@, meta, [{key, _, context}]} <- Macro.prewalker(ast),
        is_atom(key) and is_atom(context),
        do: read(key, meta, file)
  end

  defp read(key, meta, file) do
    line = meta[:line]
    column = meta[:column]
    # `@` plus the key name
    stop = column + 1 + String.length(Atom.to_string(key))
    %Read{key: key, span: Span.new(file, {line, column}, {line, stop})}
  end
end
