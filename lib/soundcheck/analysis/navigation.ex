defmodule Soundcheck.Analysis.Navigation do
  @moduledoc false
  # The paths a LiveView patches or navigates to: `push_patch` and
  # `push_navigate` calls in its functions run on the server; `<.link patch>`,
  # `<.link navigate>`, `JS.patch`, and `JS.navigate` in its `render/1`
  # template or its functions run on the client.

  alias Soundcheck.Analysis.Anchors
  alias Soundcheck.Analysis.Calls
  alias Soundcheck.Analysis.Components
  alias Soundcheck.Elixir.ModuleIndex
  alias Soundcheck.Elixir.ModuleIndex.Entry
  alias Soundcheck.Graph
  alias Soundcheck.Heex.Node
  alias Soundcheck.Heex.Reads
  alias Soundcheck.Heex.Walker
  alias Soundcheck.Span

  @type kind :: :patch | :navigate

  @type origin :: :server | :client

  @doc """
  `{path_ast, span, anchor}` for every `kind` transition in `entry`, calls
  first, then template links. `origins` selects server-side calls
  (`:server`) and client-side links (`:client`): LiveView handles a patch
  from the client differently from one the server pushes.
  """
  @spec targets(Graph.t(), Entry.t(), kind(), [origin()]) :: [{Macro.t(), Span.t(), Span.t()}]
  def targets(graph, entry, kind, origins \\ [:server, :client]) do
    server = if :server in origins, do: server_targets(entry, kind), else: []
    client = if :client in origins, do: client_targets(graph, entry, kind), else: []
    server ++ client
  end

  defp server_targets(entry, kind) do
    function = function(kind)

    calls =
      for clause <- ModuleIndex.clauses(entry),
          {path, meta} <- calls(clause.body, function) do
        stop = {meta[:line], meta[:column] + String.length(Atom.to_string(function))}
        span = Span.new(entry.file, {meta[:line], meta[:column]}, stop)
        {path, span, span}
      end

    Enum.sort_by(calls, fn {_path, span, _anchor} -> span.start end)
  end

  defp client_targets(graph, entry, kind) do
    templates = Components.render_templates(graph, entry.name)

    links =
      for template <- templates,
          %Node.Element{tag: ".link", attrs: attrs} <- Walker.elements(template.root),
          %Node.Attr{name: name, value: value} <- attrs,
          name == Atom.to_string(kind),
          {path, span} <- [link_path(value)],
          do: {template, path, span}

    template_js =
      for template <- templates,
          ast <- Reads.expressions(template),
          {path, span} <- js_commands(ast, kind, template.file),
          do: {template, path, span}

    code_js =
      for clause <- ModuleIndex.clauses(entry),
          {path, span} <- js_commands(clause.body, kind, entry.file),
          do: {path, span, span}

    in_templates =
      for {template, path, span} <- links ++ template_js,
          do: {path, span, Anchors.for_template(graph, template, span)}

    Enum.sort_by(in_templates ++ code_js, fn {_path, span, _anchor} -> {span.file, span.start} end)
  end

  # `JS.patch(path)` and `JS.navigate(path)`, also piped (`JS.patch(js,
  # path)`) or with options; the path is the first argument that can be
  # one.
  defp js_commands(ast, kind, file) do
    for {{:., _, [{:__aliases__, meta, alias}, ^kind]}, _, args} <- Macro.prewalker(ast),
        alias in [[:JS], [:Phoenix, :LiveView, :JS]] and is_list(args),
        path = Enum.find(args, &path?/1),
        do: {path, Span.covering(file, meta, Enum.join(alias ++ [kind], "."))}
  end

  defp path?(path) when is_binary(path), do: true
  defp path?({:sigil_p, _, _}), do: true
  defp path?({:<<>>, _, _}), do: true
  defp path?(_ast), do: false

  defp function(:patch), do: :push_patch
  defp function(:navigate), do: :push_navigate

  defp link_path({:string, path, _delimiter, span}), do: {path, span}
  defp link_path({:expr, ast, _source, span}), do: {ast, span}

  defp calls(body, function) do
    for {_function, meta, args} <- Calls.named(body, [function], remote: :any),
        path = Enum.find_value(args, &(Keyword.keyword?(&1) && &1[:to])),
        do: {path, meta}
  end
end
