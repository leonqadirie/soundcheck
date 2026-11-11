defmodule Soundcheck.Check.Warning.CrashingMatchInCallback do
  use Soundcheck.Check,
    id: "SC603",
    base_priority: :normal,
    category: :warning,
    confidence: :medium,
    tier: :syntactic,
    default: false,
    summary:
      "`{:ok, _} = call()` matches in LiveView callbacks, which crash the process and lose unsaved state when the call fails",
    explanations: [
      check: """
      Flags tagged-tuple matches on a call's result, such as
      `{:ok, post} = Blog.update_post(...)`, in LiveView and LiveComponent
      callbacks. When the call returns anything else, the match raises, the
      LiveView process crashes, and the browser remounts it: the user sees
      a flash of reloading and loses unsaved state, such as form input.

      Before:

          def handle_event("save", %{"post" => params}, socket) do
            {:ok, post} = Blog.update_post(socket.assigns.post, params)
            {:noreply, assign(socket, :post, post)}
          end

      After:

          def handle_event("save", %{"post" => params}, socket) do
            case Blog.update_post(socket.assigns.post, params) do
              {:ok, post} -> {:noreply, assign(socket, :post, post)}
              {:error, changeset} -> {:noreply, assign(socket, :form, to_form(changeset))}
            end
          end

      The check looks at `mount/3`, `handle_params/3`, `handle_event/3`,
      `handle_info/2`, `handle_async/3`, and `update/2`, and at matches
      whose left side is a tuple tagged with an atom (`{:ok, _}`,
      `{:error, _}`, `{:ok, _, _}`) and whose right side is a function call
      or a pipe ending in one. Matches inside anonymous functions are
      skipped: they run elsewhere, such as in `start_async/3`. Helpers the
      callbacks call are not followed. A match that should crash, because
      failure means a bug, is fine; silence it with a
      `soundcheck:disable-next-line SC603` comment that says so.
      """
    ]

  alias Soundcheck.Analysis.Calls
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph
  alias Soundcheck.Span

  @callbacks [
    {:mount, 3},
    {:handle_params, 3},
    {:handle_event, 3},
    {:handle_info, 2},
    {:handle_async, 3},
    {:update, 2}
  ]

  # Calls with these names are language constructs, not function calls.
  @constructs [
    :case,
    :cond,
    :if,
    :unless,
    :with,
    :try,
    :receive,
    :for,
    :fn,
    :quote,
    :__block__,
    :__aliases__,
    :{},
    :%{},
    :%,
    :<<>>,
    :^,
    :@
  ]

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, _params) do
    for %{kind: kind} = entry <- graph.modules,
        kind in [:live_view, :live_component],
        {name, arity} = callback <- @callbacks,
        clause <- Map.get(entry.functions, callback, []),
        {tag, call} <- matches(clause.body),
        {{line, column}, written} <- [describe(call, entry.aliases)] do
      span = Span.new(entry.file, {line, column}, {line, column + String.length(written)})

      Diagnostic.new(
        __MODULE__,
        span,
        "`{#{inspect(tag)}, ...} = #{written}(...)` in `#{name}/#{arity}` crashes the " <>
          "#{kind_name(kind)} when the call returns anything else, and the user loses " <>
          "unsaved state.",
        suggestion: "Handle the other results with `case` or `with`."
      )
    end
  end

  # `{tag, call}` for every tagged-tuple match on a call, in source order.
  defp matches(body) do
    {_ast, found} =
      Macro.prewalk(body, [], fn
        {:fn, _, _clauses}, acc ->
          {nil, acc}

        {:=, _, [pattern, value]} = node, acc ->
          with {:ok, tag} <- tag(pattern),
               {:ok, call} <- call(value) do
            {node, [{tag, call} | acc]}
          else
            _not_a_tagged_call_match -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  # Two-element tuples are literals in the AST; longer ones are `:{}` nodes.
  defp tag({tag, _value}) when is_atom(tag) and tag not in [nil, true, false], do: {:ok, tag}

  defp tag({:{}, _, [tag | _rest]}) when is_atom(tag) and tag not in [nil, true, false],
    do: {:ok, tag}

  defp tag(_pattern), do: :error

  # A pipe's value is its last call's.
  defp call({:|>, _, [_left, right]}), do: call(right)

  # `socket.assigns.post` parses as a call without parentheses: field access.
  defp call({{:., _, [_module, fun]}, meta, args} = call) when is_atom(fun) and is_list(args),
    do: if(meta[:no_parens], do: :error, else: {:ok, call})

  defp call({name, _, args} = call) when is_atom(name) and is_list(args) do
    if name in @constructs or Macro.operator?(name, length(args)),
      do: :error,
      else: {:ok, call}
  end

  defp call(_value), do: :error

  defp describe({{:., _, [_module, _fun]}, _, _args} = call, aliases) do
    [%{start: start, written: written} | _] = Calls.remote(call, aliases)
    {start, written}
  end

  defp describe({name, meta, _args}, _aliases),
    do: {{meta[:line], meta[:column]}, Atom.to_string(name)}

  defp kind_name(:live_view), do: "LiveView"
  defp kind_name(:live_component), do: "LiveComponent's LiveView"
end
