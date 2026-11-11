defmodule Soundcheck.Analysis.Streams do
  @moduledoc false
  # LiveView streams in templates: where `@streams.name` is read, which
  # elements loop over a stream, and which elements are stream containers
  # (`phx-update="stream"`).
  #
  # `@streams.name` and `@streams[:name]` both count as reads of stream
  # `name`.

  alias Soundcheck.Heex.Node
  alias Soundcheck.Heex.Template
  alias Soundcheck.Span

  defmodule Read do
    @moduledoc false
    # One `@streams.name` or `@streams[:name]` read. The span starts at
    # `@streams`; `ast` is the read expression.
    @enforce_keys [:name, :span, :ast]
    defstruct [:name, :span, :ast]

    @type t :: %__MODULE__{name: atom(), span: Span.t(), ast: Macro.t()}
  end

  defmodule Loop do
    @moduledoc false
    # An element whose `:for` loops over the stream `stream`, with the
    # element that contains it (`nil` at the template root).
    @enforce_keys [:element, :parent, :stream]
    defstruct [:element, :parent, :stream]

    @type t :: %__MODULE__{
            element: Node.Element.t(),
            parent: Node.Element.t() | nil,
            stream: atom()
          }
  end

  @type read :: Read.t()
  @type loop :: Loop.t()

  @doc """
  Every element that loops over a stream with `:for`, with the element that
  contains it (`nil` at the template root).
  """
  @spec loops(Template.t()) :: [loop()]
  def loops(%Template{root: root}) do
    for {element, parent} <- with_parents(root, nil),
        %Node.Attr{name: ":for", value: {:expr, {:<-, _, [_pattern, source]}, _source, _span}} <-
          element.attrs,
        {:ok, name} <- [stream_name(source)],
        do: %Loop{element: element, parent: parent, stream: name}
  end

  @doc "Every element with `phx-update=\"stream\"`."
  @spec containers(Template.t()) :: [Node.Element.t()]
  def containers(%Template{root: root}) do
    for {element, _parent} <- with_parents(root, nil),
        Enum.any?(
          element.attrs,
          &match?(%Node.Attr{name: "phx-update", value: {:string, "stream", _, _}}, &1)
        ),
        do: element
  end

  @doc """
  Every `@streams.name` read that a template passes straight to an
  enumerating function (`Enum`, `List`, `Stream`, `Map`, `MapSet`,
  `Keyword`, `length/1`, `hd/1`, `tl/1`). LiveView raises on those: a
  stream implements `Enumerable` only to fail loudly outside a
  comprehension. Passing a stream to a component attribute, which then
  iterates it, is fine and not returned.
  """
  @spec enumerations(Template.t()) :: [read()]
  def enumerations(%Template{root: root, file: file}) do
    for ast <- root |> expressions([]) |> Enum.reverse(),
        read <- enumerated(ast, file),
        do: read
  end

  # ── Traversal ──

  defp with_parents(nodes, parent) when is_list(nodes),
    do: Enum.flat_map(nodes, &with_parents(&1, parent))

  defp with_parents(%Node.Element{children: children} = element, parent),
    do: [{element, parent} | with_parents(children, element)]

  defp with_parents(%Node.EexBlock{clauses: clauses}, parent),
    do: Enum.flat_map(clauses, &with_parents(&1.children, parent))

  defp with_parents(_node, _parent), do: []

  # Every expression AST in the tree, in reverse source order.
  defp expressions(nodes, acc) when is_list(nodes), do: Enum.reduce(nodes, acc, &expressions/2)

  defp expressions(%Node.Element{attrs: attrs, children: children}, acc) do
    acc =
      for %Node.Attr{value: {:expr, ast, _source, _span}} <- attrs,
          reduce: acc,
          do: (acc -> [ast | acc])

    expressions(children, acc)
  end

  defp expressions(%Node.BodyExpr{ast: ast}, acc), do: [ast | acc]
  defp expressions(%Node.Eex{ast: ast}, acc), do: [ast | acc]

  defp expressions(%Node.EexBlock{head: %{ast: ast}, clauses: clauses}, acc),
    do: Enum.reduce(clauses, [ast | acc], &expressions(&1.children, &2))

  defp expressions(_node, acc), do: acc

  # ── Stream reads ──

  @enumerating_modules [:Enum, :List, :Stream, :Map, :MapSet, :Keyword]
  @enumerating_locals [:length, :hd, :tl]

  defp enumerated({:error, _reason}, _file), do: []

  defp enumerated(ast, file) do
    for node <- Macro.prewalker(ast),
        enumerating_call?(node),
        read <- stream_args(node, file),
        do: read
  end

  defp stream_args({_name, _meta, args}, file) do
    for arg <- args,
        {:ok, name} <- [stream_name(arg)],
        do: %Read{name: name, span: span(arg, name, file), ast: arg}
  end

  defp enumerating_call?({{:., _, [{:__aliases__, _, [module]}, _fun]}, _, args})
       when is_list(args), do: module in @enumerating_modules

  defp enumerating_call?({name, _, args}) when is_atom(name) and is_list(args),
    do: name in @enumerating_locals

  defp enumerating_call?(_node), do: false

  defp stream_name({{:., _, [{:@, _, [{:streams, _, context}]}, name]}, _, []})
       when is_atom(context) and is_atom(name), do: {:ok, name}

  defp stream_name({{:., _, [Access, :get]}, _, [{:@, _, [{:streams, _, context}]}, name]})
       when is_atom(context) and is_atom(name), do: {:ok, name}

  defp stream_name(_node), do: :error

  # The read starts at `@streams`.
  defp span({{:., _, [Access, :get]}, _, [{:@, meta, _}, _name]}, name, file),
    do: Span.covering(file, meta, "@streams[:#{name}]")

  defp span({{:., _, [{:@, meta, _}, _name]}, _, _args}, name, file),
    do: Span.covering(file, meta, "@streams.#{name}")
end
