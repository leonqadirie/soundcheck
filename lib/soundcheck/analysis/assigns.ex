defmodule Soundcheck.Analysis.Assigns do
  @moduledoc false
  # Which assign keys LiveView callbacks set, by abstract interpretation of
  # their source.
  #
  # The interpreter tracks the keys an expression may assign, along every
  # path, for one context: the disconnected (HTTP) or the connected
  # (websocket) run of `mount/3`. `if connected?(socket)` and its negations
  # pick the branch for the context; any other branch joins.
  #
  # Most closures are skipped: `assign_async/3` and `assign_new/3` functions
  # run later or not at all. A closure given to `then/2`, or to an `Enum`,
  # `Map`, `Keyword`, or `List` call that receives the socket, runs inline:
  # its parameters count as sockets, and the interpreter evaluates its body
  # once for `then/2` and zero or more times for the others.
  #
  # A call soundcheck does not model that receives the socket could assign
  # anything, so it makes the result `open`: rules then make no claim about
  # which keys are unset.
  #
  # `push_navigate/2` and `redirect/2` halt a path: a mount that navigates
  # away never renders, so joins drop halted paths, and a result is `halted?`
  # only when every path halts.

  alias Soundcheck.Beam.DebugInfo
  alias Soundcheck.Graph
  alias Soundcheck.Heex.Template

  defmodule Result do
    @moduledoc false
    # What the interpreter knows after evaluating code: the keys it may assign
    # on some path (`may`) and assigns on every path (`must`), whether it is
    # open, whether every path halts, and the variable names bound to the
    # socket so far (`sockets`).
    defstruct may: MapSet.new(),
              must: MapSet.new(),
              open?: false,
              halted?: false,
              sockets: MapSet.new()

    @type t :: %__MODULE__{
            may: MapSet.t(atom()),
            must: MapSet.t(atom()),
            open?: boolean(),
            halted?: boolean(),
            sockets: MapSet.t(atom())
          }

    @doc """
    Joins two alternative paths: a key may be set if either path sets it,
    and must be set only if both do. The join is open if either path is,
    and halted only if both are.
    """
    @spec join(t(), t()) :: t()
    def join(%__MODULE__{} = a, %__MODULE__{} = b),
      do: %__MODULE__{
        may: MapSet.union(a.may, b.may),
        must: MapSet.intersection(a.must, b.must),
        open?: a.open? or b.open?,
        halted?: a.halted? and b.halted?,
        sockets: MapSet.union(a.sockets, b.sockets)
      }
  end

  @type result :: Result.t()

  # Calls that assign the keys named in their literal arguments.
  @assigning [:assign, :assign_new, :update, :assign_async]

  # Calls that set a fixed key.
  @fixed %{stream: :streams, allow_upload: :uploads}

  # Socket functions after which the callback renders nothing.
  @halting [:push_navigate, :redirect]

  # Socket functions that change no assigns soundcheck tracks.
  @neutral [
    :connected?,
    :put_flash,
    :clear_flash,
    :push_event,
    :push_patch,
    :start_async,
    :cancel_async,
    :stream_configure,
    :attach_hook,
    :detach_hook,
    :subscribe,
    :get_connect_params,
    :get_connect_info,
    :put_private
  ]

  @doc """
  Interprets the `mount/3` clauses for one context. `connected?` selects
  the branch of `if connected?(socket)`.
  """
  @spec mount(list(map()), boolean()) :: result()
  def mount(clauses, connected?) do
    clauses
    |> Enum.map(fn clause ->
      sockets = clause.args |> List.last() |> socket_var() |> List.wrap() |> MapSet.new()
      eval(clause.body, %{connected?: connected?}, %{empty() | sockets: sockets})
    end)
    |> join_all(empty())
  end

  @doc """
  The keys the function owning `template` assigns on every path before the
  template renders: those of the clause holding an inline `~H` template,
  or of every clause for a template file. `:open` when a call there may
  assign any key.
  """
  @spec render_keys(Graph.t(), Template.t()) :: {:ok, MapSet.t(atom())} | :open
  def render_keys(%Graph{} = graph, %Template{owner: {module, fun}} = template) do
    clauses =
      case Graph.module(graph, module) do
        %{functions: functions} -> Map.get(functions, {fun, 1}, [])
        nil -> []
      end

    owner_keys(clauses, template)
  end

  def render_keys(_graph, %Template{owner: nil}), do: {:ok, MapSet.new()}

  defp owner_keys(clauses, %Template{origin: :sigil, id: {_file, {line, _column}}}) do
    clauses
    |> Enum.filter(&(&1.line <= line))
    |> Enum.max_by(& &1.line, fn -> nil end)
    |> List.wrap()
    |> render_must()
  end

  defp owner_keys(clauses, %Template{}), do: render_must(clauses)

  defp render_must(clauses) do
    result = mount(clauses, true)
    if result.open?, do: :open, else: {:ok, result.must}
  end

  @doc """
  The keys the source clauses may assign on any path, in either context.
  """
  @spec any_path(list(map())) :: result()
  def any_path(clauses), do: join_all([mount(clauses, true), mount(clauses, false)], empty())

  @doc """
  The keys a compiled hook module's `on_mount/4` may assign, read from its
  expanded AST: every literal key passed to `Phoenix.Component.assign/2,3`
  and the other assigning calls, in `on_mount/4` and in the module's own
  functions it calls or captures (`attach_hook(socket, :uri,
  :handle_params, &set_uri/3)`), transitively. Returns `:unknown` when the
  module cannot be read.
  """
  @spec on_mount_keys(module()) :: {:ok, MapSet.t(atom())} | :unknown
  def on_mount_keys(module) do
    case DebugInfo.definitions(module) do
      {:ok, %DebugInfo.Info{definitions: definitions}} ->
        functions =
          Map.new(definitions, fn {name_arity, _kind, _meta, clauses} -> {name_arity, clauses} end)

        {:ok, reachable_keys([{:on_mount, 4}], {module, functions}, %{}, MapSet.new())}

      {:error, _reason} ->
        :unknown
    end
  end

  defp reachable_keys([], _functions, _seen, keys), do: keys

  defp reachable_keys([function | rest], {module, functions} = defined, seen, keys) do
    if Map.has_key?(seen, function) do
      reachable_keys(rest, defined, seen, keys)
    else
      bodies = for {_meta, _args, _guards, body} <- Map.get(functions, function, []), do: body
      keys = Enum.into(Enum.flat_map(bodies, &expanded_keys/1), keys)

      next =
        for body <- bodies,
            node <- Macro.prewalker(body),
            reference = local_reference(node, module),
            Map.has_key?(functions, reference),
            uniq: true,
            do: reference

      reachable_keys(next ++ rest, defined, Map.put(seen, function, true), keys)
    end
  end

  # Calls (`set_uri(params, uri, socket)`) and captures (`&set_uri/3`,
  # `&Hook.set_uri/3`) of the module's own functions.
  defp local_reference({:&, _, [{:/, _, [{name, _, context}, arity]}]}, _module)
       when is_atom(name) and is_atom(context) and is_integer(arity), do: {name, arity}

  defp local_reference({:&, _, [{:/, _, [{{:., _, [module, name]}, _, []}, arity]}]}, module)
       when is_atom(name) and is_integer(arity), do: {name, arity}

  defp local_reference({name, _meta, args}, _module) when is_atom(name) and is_list(args),
    do: {name, length(args)}

  defp local_reference(_node, _module), do: nil

  # ── Interpreter ──

  defp empty, do: %Result{}

  # Alternative paths: a key may be set if some path sets it, and must be set
  # only if every path sets it. Halted paths never render, so they join only
  # when every path halts. No paths leaves `fallback`.
  defp join_all([], fallback), do: fallback

  defp join_all(states, _fallback) do
    case Enum.reject(states, & &1.halted?) do
      [] -> join_paths(states)
      running -> join_paths(running)
    end
  end

  defp join_paths([first | rest]), do: Enum.reduce(rest, first, &Result.join(&2, &1))

  defp eval({:__block__, _, expressions}, ctx, state),
    do: Enum.reduce(expressions, state, &eval(&1, ctx, &2))

  defp eval({kind, _, [condition, branches]}, ctx, state)
       when kind in [:if, :unless] and is_list(branches) do
    branches = Keyword.new(branches)

    {taken, other} =
      if kind == :if, do: {branches[:do], branches[:else]}, else: {branches[:else], branches[:do]}

    case connected_condition(condition) do
      {:connected, true} -> eval(if(ctx.connected?, do: taken, else: other), ctx, state)
      {:connected, false} -> eval(if(ctx.connected?, do: other, else: taken), ctx, state)
      :other -> state |> then(&eval(condition, ctx, &1)) |> branch_join([taken, other], ctx)
    end
  end

  defp eval({:case, _, [subject, [do: clauses]]}, ctx, state),
    do: eval(subject, ctx, state) |> branch_join(arrow_bodies(clauses), ctx)

  defp eval({:cond, _, [[do: clauses]]}, ctx, state),
    do: branch_join(state, arrow_bodies(clauses), ctx)

  defp eval({:with, _, args}, ctx, state) do
    {clauses, blocks} = Enum.split_with(args, &(not is_list(&1)))
    state = Enum.reduce(clauses, state, &eval(&1, ctx, &2))

    bodies =
      for block <- blocks, {_key, body} <- block, body <- List.wrap(arrow_or_body(body)), do: body

    # Without `else`, a failing clause skips the body: that path is `nil`.
    else? = Enum.any?(blocks, &Keyword.has_key?(&1, :else))
    branch_join(state, if(else?, do: bodies, else: [nil | bodies]), ctx)
  end

  # `new_socket = assign(socket, ...)` keeps tracking the socket under the
  # new name.
  defp eval({:=, _, [left, right]}, ctx, state) do
    after_right = eval(right, ctx, state)

    case {socket?(right, state), var_name(left)} do
      {true, name} when not is_nil(name) ->
        %{after_right | sockets: MapSet.put(after_right.sockets, name)}

      _other ->
        after_right
    end
  end

  defp eval({:|>, _, [left, right]}, ctx, state) do
    after_left = eval(left, ctx, state)
    call(right, socket?(left, state), ctx, after_left)
  end

  defp eval({:fn, _, _clauses}, _ctx, state), do: state

  defp eval({{:., _, [_module, _name]}, _, args} = node, ctx, state) when is_list(args),
    do: call(node, false, ctx, state)

  defp eval({name, _, args} = node, ctx, state) when is_atom(name) and is_list(args),
    do: call(node, false, ctx, state)

  defp eval({left, right}, ctx, state), do: eval(right, ctx, eval(left, ctx, state))
  defp eval(list, ctx, state) when is_list(list), do: Enum.reduce(list, state, &eval(&1, ctx, &2))
  defp eval(_leaf, _ctx, state), do: state

  # Each branch continues from `state`; a missing branch (`nil`) leaves it
  # unchanged, so an `if` without `else` keeps only what `state` already must
  # set.
  defp branch_join(state, bodies, ctx) do
    bodies
    |> Enum.map(&eval(&1, ctx, state))
    |> join_all(state)
  end

  defp arrow_bodies(clauses), do: for({:->, _, [_patterns, body]} <- clauses, do: body)

  defp arrow_or_body(body) when is_list(body), do: arrow_bodies(body)
  defp arrow_or_body(body), do: body

  # `piped?` is true when the call is the right side of a pipe whose left
  # side is the socket. Assigning calls count whatever they receive: tracking
  # misses only widen the keys a context may set, which rules read as "maybe
  # set" and never report.
  defp call(node, piped?, ctx, state) do
    {name, args} = name_and_args(node)
    receives_socket? = piped? or Enum.any?(args, &socket?(&1, state))

    cond do
      name in @assigning -> assign_keys(args, state)
      Map.has_key?(@fixed, name) -> add_keys(state, [Map.fetch!(@fixed, name)])
      name in @halting -> %{eval(args, ctx, state) | halted?: true}
      name in @neutral -> eval(args, ctx, state)
      receives_socket? -> socket_call(node, name, args, ctx, state)
      true -> eval(args, ctx, state)
    end
  end

  # A call that is not an assigning or neutral socket function but receives
  # the socket: `then/2` and standard-library calls run their closures
  # inline; anything else could assign any key.
  defp socket_call(node, name, args, ctx, state) do
    cond do
      name == :then -> closures(args, :once, ctx, state)
      kernel?(node) -> closures(args, :maybe, ctx, state)
      true -> %{eval(args, ctx, state) | open?: true}
    end
  end

  # Evaluates the call's arguments, then each closure among them as a
  # branch: once (`then/2`) or possibly not at all (`Enum.reduce/3` over an
  # empty list). Closure parameters count as sockets inside the body; the
  # bound names do not leak out.
  defp closures(args, runs, ctx, state) do
    args
    |> Enum.filter(&match?({:fn, _, _}, &1))
    |> Enum.reduce(eval(args, ctx, state), fn {:fn, _, clauses}, acc ->
      inner = %{acc | sockets: MapSet.union(acc.sockets, param_vars(clauses))}
      bodies = arrow_bodies(clauses)
      joined = branch_join(inner, if(runs == :once, do: bodies, else: [nil | bodies]), ctx)
      %{joined | sockets: acc.sockets}
    end)
  end

  defp param_vars(clauses) do
    params = for {:->, _, [params, _body]} <- clauses, do: params

    for {name, _, context} when is_atom(name) and is_atom(context) <- Macro.prewalker(params),
        into: MapSet.new(),
        do: name
  end

  defp name_and_args({{:., _, [_module, name]}, _, args}), do: {name, args}
  defp name_and_args({name, _, args}), do: {name, args}

  defp kernel?({{:., _, [{:__aliases__, _, [module]}, _name]}, _, _args}),
    do: module in [:Enum, :Map, :Keyword, :List, :String, :Logger]

  defp kernel?(_node), do: false

  # A key argument that names no literal key (a map or a variable) could
  # name any key.
  defp assign_keys(args, state) do
    case literal_keys(args) do
      [] -> %{state | open?: true}
      keys -> add_keys(state, keys)
    end
  end

  defp add_keys(state, keys),
    do: %{state | may: Enum.into(keys, state.may), must: Enum.into(keys, state.must)}

  defp socket?({name, _, context}, state) when is_atom(name) and is_atom(context),
    do: MapSet.member?(state.sockets, name)

  defp socket?({:|>, _, [left, _right]}, state), do: socket?(left, state)

  defp socket?({{:., _, [_module, _name]}, _, [first | _]}, state), do: socket?(first, state)
  defp socket?({name, _, [first | _]}, state) when is_atom(name), do: socket?(first, state)
  defp socket?(_expr, _state), do: false

  defp var_name({name, _, context}) when is_atom(name) and is_atom(context), do: name
  defp var_name(_pattern), do: nil

  defp socket_var({:=, _, [left, right]}), do: socket_var(left) || socket_var(right)
  defp socket_var({name, _, context}) when is_atom(name) and is_atom(context), do: name
  defp socket_var(_pattern), do: nil

  defp connected_condition({:connected?, _, [_socket]}), do: {:connected, true}

  defp connected_condition({{:., _, [_module, :connected?]}, _, [_socket]}),
    do: {:connected, true}

  defp connected_condition({negation, _, [condition]}) when negation in [:not, :!] do
    case connected_condition(condition) do
      {:connected, polarity} -> {:connected, not polarity}
      :other -> :other
    end
  end

  defp connected_condition(_condition), do: :other

  # ── Expanded AST (hook modules) ──

  defp expanded_keys(body) do
    for {{:., _, [module, name]}, _, args} <- Macro.prewalker(body),
        module in [Phoenix.Component, Phoenix.LiveView] and name in @assigning and is_list(args),
        key <- literal_keys(args),
        do: key
  end

  @doc """
  The keys an assigning call's key argument names: a literal atom, the keys
  of a keyword list, or the atoms of a list (`assign_async/3`). A map or
  variable names none.

  The key argument comes first in a piped call and second otherwise, after
  the socket or assigns. Later arguments are values: the `:short` of
  `assign(socket, :mode, :short)` names no key.
  """
  @spec literal_keys([Macro.t()]) :: [atom()]
  def literal_keys(args), do: args |> Enum.take(2) |> Enum.find_value([], &key_argument/1)

  defp key_argument(key) when is_atom(key) and not is_nil(key) and not is_boolean(key), do: [key]
  defp key_argument([{key, _value} | _] = keyword) when is_atom(key), do: Keyword.keys(keyword)
  defp key_argument([key | _] = list) when is_atom(key), do: Enum.filter(list, &is_atom/1)
  defp key_argument(_other), do: nil
end
