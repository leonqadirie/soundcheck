defmodule Soundcheck.Analysis.Calls do
  @moduledoc false
  # Remote calls in a function body, as written in source.
  #
  # Closures are skipped: their bodies run later, if at all (a function given
  # to `assign_async/3` or `Task.async/1`). Closures given to `then/2`,
  # `tap/2`, or an `Enum`, `Map`, `Keyword`, or `List` call run inline, so
  # their calls count. With `guard: :connected`, calls that only the
  # connected run reaches are skipped too: a branch of `if connected?(socket)`
  # or of a compound such as `if connected?(socket) and flag?()`, and the
  # operands after `connected?(socket) and`.

  alias Soundcheck.Analysis.Connected
  alias Soundcheck.Elixir.ModuleIndex

  defmodule Call do
    @moduledoc false
    # One remote call. `module` and `qualified` (`"MyApp.Repo.all"`) are `nil`
    # when the module is dynamic; `written` is the call as the source spells
    # it, and `start` is the position of its module.
    @enforce_keys [:qualified, :module, :fun, :written, :start, :arity]
    defstruct [:qualified, :module, :fun, :written, :start, :arity]

    @type t :: %__MODULE__{
            qualified: String.t() | nil,
            module: module() | nil,
            fun: atom(),
            written: String.t(),
            start: Soundcheck.Span.position(),
            arity: non_neg_integer()
          }
  end

  @type call :: Call.t()

  @doc """
  The remote calls in `body`, in source order. `aliases` expands module
  aliases. Options: `guard: :connected` skips connected-only branches.
  """
  @spec remote(Macro.t(), %{atom() => module()}, keyword()) :: [call()]
  def remote(body, aliases, opts \\ []) do
    guard? = Keyword.get(opts, :guard) == :connected

    body
    |> collect(false, guard?, [])
    |> Enum.reverse()
    |> Enum.map(&describe(&1, aliases))
  end

  @doc """
  Calls to a function in `names`, in source order, as `{name, meta, args}`.
  Matches local calls and remote calls through a module that `:remote`
  allows: a list of alias segment lists (default `[[:Phoenix, :LiveView]]`)
  or `:any`. Unlike `remote/3`, it walks into closures.
  """
  @spec named(Macro.t(), [atom()], keyword()) :: [{atom(), keyword(), [Macro.t()]}]
  def named(ast, names, opts \\ []) do
    remote = Keyword.get(opts, :remote, [[:Phoenix, :LiveView]])

    ast
    |> Macro.prewalker()
    |> Enum.flat_map(fn
      {name, meta, args} when is_atom(name) and is_list(args) ->
        if name in names, do: [{name, meta, args}], else: []

      {{:., _, [module, name]}, meta, args} when is_atom(name) and is_list(args) ->
        if name in names and remote?(module, remote), do: [{name, meta, args}], else: []

      _node ->
        []
    end)
  end

  defp remote?(_module, :any), do: true
  defp remote?({:__aliases__, _, segments}, allowed), do: segments in allowed
  defp remote?(_module, _allowed), do: false

  defp describe({{:., _, [module_ast, fun]}, meta, args}, aliases) do
    module = if is_atom(module_ast), do: module_ast, else: ModuleIndex.expand(module_ast, aliases)
    module = if is_atom(module), do: module

    %Call{
      qualified: module && "#{inspect(module)}.#{fun}",
      module: module,
      fun: fun,
      written: "#{written_module(module_ast)}.#{fun}",
      start: start(module_ast, meta),
      arity: length(args)
    }
  end

  defp written_module(atom) when is_atom(atom), do: inspect(atom)
  defp written_module(ast), do: Macro.to_string(ast)

  # A remote call's own metadata points at the function name; the written
  # call starts at the module alias.
  defp start({:__aliases__, alias_meta, _segments}, meta),
    do: {alias_meta[:line] || meta[:line], alias_meta[:column] || meta[:column]}

  # An Erlang module call (`:timer.sleep`) has no alias metadata; the module
  # sits right before the function name.
  defp start(module, meta) when is_atom(module),
    do: {meta[:line], meta[:column] - String.length(inspect(module)) - 1}

  defp start(_module, meta), do: {meta[:line], meta[:column]}

  defp collect({kind, _, [condition, branches]}, skipping?, guard?, acc)
       when guard? and kind in [:if, :unless] and is_list(branches) do
    branches = Keyword.new(branches)

    {taken, other} =
      if kind == :if, do: {branches[:do], branches[:else]}, else: {branches[:else], branches[:do]}

    # `guard: :connected` keeps what the disconnected run can reach: the
    # operands it evaluates and the branch its outcome selects.
    outcome = Connected.outcome(condition, false)

    acc =
      condition
      |> Connected.reachable(false)
      |> Enum.reduce(acc, &collect(&1, skipping?, guard?, &2))

    acc = collect(taken, skipping? or outcome == false, guard?, acc)
    collect(other, skipping? or outcome == true, guard?, acc)
  end

  defp collect({:fn, _, _clauses}, _skipping?, _guard?, acc), do: acc

  defp collect({{:., _, [module, fun]}, _meta, args} = call, skipping?, guard?, acc)
       when is_atom(fun) and is_list(args) do
    acc = if skipping?, do: acc, else: [call | acc]
    args = if eager_module?(module), do: inline_closures(args), else: args
    collect(args, skipping?, guard?, acc)
  end

  defp collect({name, _, args}, skipping?, guard?, acc)
       when name in [:then, :tap] and is_list(args),
       do: collect(inline_closures(args), skipping?, guard?, acc)

  defp collect({form, _, args}, skipping?, guard?, acc) when is_list(args),
    do: collect(args, skipping?, guard?, collect(form, skipping?, guard?, acc))

  defp collect({left, right}, skipping?, guard?, acc),
    do: collect(right, skipping?, guard?, collect(left, skipping?, guard?, acc))

  defp collect(list, skipping?, guard?, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect(&1, skipping?, guard?, &2))

  defp collect(_leaf, _skipping?, _guard?, acc), do: acc

  # Modules whose functions call a closure argument before they return.
  defp eager_module?({:__aliases__, _, [module]}), do: module in [:Enum, :Map, :Keyword, :List]
  defp eager_module?(_module), do: false

  defp inline_closures(args) do
    Enum.map(args, fn
      {:fn, _, clauses} -> for {:->, _, [_params, body]} <- clauses, do: body
      arg -> arg
    end)
  end
end
