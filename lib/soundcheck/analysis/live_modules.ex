defmodule Soundcheck.Analysis.LiveModules do
  @moduledoc false
  # Pairs the graph's source-indexed modules with what their compiled form
  # says they are.

  alias Soundcheck.Analysis.Handlers.HandlerSet
  alias Soundcheck.Analysis.Handlers.Sender
  alias Soundcheck.Beam.Introspect
  alias Soundcheck.Diagnostic
  alias Soundcheck.Elixir.ModuleIndex
  alias Soundcheck.Elixir.ModuleIndex.Entry
  alias Soundcheck.Graph
  alias Soundcheck.Span

  @type kind :: :view | :component

  @doc """
  Maps the name of every indexed module whose compiled form is a LiveView
  (`:view`) or LiveComponent (`:component`) to that kind. A module that
  does not load gets no entry; the Configuration check reports it.

  This is the stored form of the `:live_modules` link: it holds names, so
  storing it copies no module entry. `entries/2` pairs it with the graph.
  """
  @spec kinds(Graph.t()) :: %{module() => kind()}
  def kinds(%Graph{modules: modules}) do
    for %Entry{name: name} <- modules,
        name != nil,
        {:ok, %{kind: kind}} <- [Introspect.live(name)],
        into: %{},
        do: {name, kind}
  end

  @doc """
  Returns `{entry, kind}` for every module of `graph` that `kinds` names,
  in graph order.
  """
  @spec entries(%{module() => kind()}, Graph.t()) :: [{Entry.t(), kind()}]
  def entries(kinds, %Graph{modules: modules}) do
    for %Entry{name: name} = entry <- modules,
        kind = Map.get(kinds, name),
        do: {entry, kind}
  end

  @doc """
  The span of a sender's call name in `entry`'s file. Macro-expanded calls
  carry no column, so the column comes from the source AST: the first call
  with the same name on the same line, or column 1 when none matches.
  """
  @spec span(Entry.t(), Sender.t()) :: Span.t()
  def span(%Entry{file: file} = entry, %Sender{line: line, column: column, call: call}) do
    name = call |> String.split(".") |> List.last()
    column = column || source_column(entry, line, String.to_existing_atom(name)) || 1
    Span.new(file, {line, column}, {line, column + String.length(name)})
  end

  defp source_column(%Entry{} = entry, line, name) do
    entry
    |> ModuleIndex.clauses()
    |> Enum.find_value(fn clause -> call_column(clause.body, line, name) end)
  end

  defp call_column(body, line, name) do
    body
    |> Macro.prewalker()
    |> Enum.find_value(fn
      {^name, meta, args} when is_list(args) ->
        if meta[:line] == line, do: meta[:column]

      {{:., _, [_module, ^name]}, meta, args} when is_list(args) ->
        if meta[:line] == line, do: meta[:column]

      _node ->
        nil
    end)
  end

  @doc "Formats a message term as source text: `:tick` or `{:loaded, ...}`."
  @spec describe(term()) :: String.t()
  def describe({:atom, atom}), do: inspect(atom)
  def describe({:tagged, tag, _size}), do: "{#{inspect(tag)}, ...}"

  @doc """
  Builds the diagnostic for a sender whose message no handler accepts:
  resolved against a closed handler set, unverifiable otherwise.
  """
  @spec unhandled(module(), Entry.t(), Sender.t(), HandlerSet.t(), String.t()) :: Diagnostic.t()
  def unhandled(rule, entry, sender, handler_set, message) do
    span = span(entry, sender)

    Diagnostic.new(rule, span, message, resolution: HandlerSet.resolution(handler_set))
  end
end
