defmodule Soundcheck.Analysis.MountHooks do
  @moduledoc false
  # The `on_mount` hooks that run before a LiveView's first render: hooks
  # the module declares and hooks from the `live_session` of every route that
  # points to it.

  alias Soundcheck.Analysis.Assigns
  alias Soundcheck.Beam.DebugInfo
  alias Soundcheck.Beam.Introspect
  alias Soundcheck.Graph

  @doc "The live routes of every router in the graph."
  @spec routes(Graph.t()) :: [Introspect.route()]
  def routes(%Graph{modules: modules}) do
    for %{kind: :router, name: router} <- modules,
        router != nil,
        {:ok, routes} <- [Introspect.live_routes(router)],
        route <- routes,
        do: route
  end

  @doc """
  Whether the `on_mount/4` clauses of `module` that accept `arg` can stop
  the mount: return `{:halt, socket}` or raise. Returns `false` only when
  every result is provably `{:cont, socket}`. Reads the compiled clauses'
  tail positions through `case`, `cond`, `if`, `with`, and local helpers;
  a tail it cannot read (a remote call, a variable) counts as able to
  halt, as does a module it cannot load.
  """
  @spec can_halt?(module(), term()) :: boolean()
  def can_halt?(module, arg) do
    case DebugInfo.clauses(module, :on_mount, 4) do
      {:ok, clauses} ->
        accepting =
          for {_meta, [first | _], _guards, body} <- clauses, accepts?(first, arg), do: body

        # No accepting clause raises FunctionClauseError, which stops the mount.
        accepting == [] or
          accepting
          |> Enum.flat_map(&outcomes(&1, module, %{{:on_mount, 4} => true}))
          |> Enum.any?(&(&1 != :cont))

      {:error, _reason} ->
        true
    end
  end

  # A clause whose first pattern is another atom never accepts `arg`; any
  # other pattern may.
  defp accepts?(pattern, arg) when is_atom(pattern), do: pattern == arg
  defp accepts?(_pattern, _arg), do: true

  # The results an expression can return, as `:cont`, `:halt`, or `:unknown`.
  defp outcomes({:__block__, _, expressions}, module, seen),
    do: expressions |> List.last() |> outcomes(module, seen)

  defp outcomes({:case, _, [_subject, [do: clauses]]}, module, seen) when is_list(clauses),
    do: Enum.flat_map(clauses, fn {:->, _, [_patterns, body]} -> outcomes(body, module, seen) end)

  defp outcomes({:cond, _, [[do: clauses]]}, module, seen) when is_list(clauses),
    do:
      Enum.flat_map(clauses, fn {:->, _, [_conditions, body]} -> outcomes(body, module, seen) end)

  # A `with` without `else` returns the first value that fails to match,
  # which can be anything.
  defp outcomes({:with, _, args}, module, seen) do
    {_clauses, [branches]} = Enum.split(args, -1)

    else_bodies = for {:->, _, [_patterns, body]} <- Keyword.get(branches, :else, []), do: body
    results = Enum.flat_map([branches[:do] | else_bodies], &outcomes(&1, module, seen))

    if Keyword.has_key?(branches, :else), do: results, else: [:unknown | results]
  end

  defp outcomes({:cont, _socket}, _module, _seen), do: [:cont]
  defp outcomes({:halt, _socket}, _module, _seen), do: [:halt]

  # `raise`, `throw`, and `exit` stop the mount as surely as `:halt`.
  defp outcomes({{:., _, [:erlang, fun]}, _, _args}, _module, _seen)
       when fun in [:error, :throw, :exit], do: [:halt]

  defp outcomes({{:., _, [module, fun]}, _, args}, module, seen) when is_atom(fun),
    do: local(module, fun, length(args), seen)

  defp outcomes({fun, _, args}, module, seen)
       when is_atom(fun) and is_list(args) and fun not in [:try, :receive, :fn, :{}, :%{}],
       do: local(module, fun, length(args), seen)

  defp outcomes(_expression, _module, _seen), do: [:unknown]

  # A recursive call adds no results beyond those of the calls around it.
  defp local(module, fun, arity, seen) do
    with false <- Map.has_key?(seen, {fun, arity}),
         {:ok, [_ | _] = clauses} <- DebugInfo.clauses(module, fun, arity) do
      seen = Map.put(seen, {fun, arity}, true)
      Enum.flat_map(clauses, fn {_meta, _args, _guards, body} -> outcomes(body, module, seen) end)
    else
      true -> []
      _undefined -> [:unknown]
    end
  end

  @doc """
  The hook modules that run on `module`'s mount: those `module` declares
  and those of every `live_session` whose routes point to it.
  """
  @spec hook_modules(module(), [Introspect.route()]) :: [module()]
  def hook_modules(module, routes) do
    module_hooks =
      case Introspect.live(module) do
        {:ok, %{on_mount: hooks}} -> hooks
        {:error, _reason} -> []
      end

    route_hooks = for %{live_view: ^module, on_mount: hooks} <- routes, hook <- hooks, do: hook

    (module_hooks ++ route_hooks)
    |> Enum.map(fn {hook, _arg} -> hook end)
    |> Enum.uniq()
  end

  @doc """
  The keys `module`'s hooks may assign, and whether every hook could be
  read.
  """
  @spec keys(module(), [Introspect.route()]) :: {MapSet.t(atom()), boolean()}
  def keys(module, routes) do
    module
    |> hook_modules(routes)
    |> Enum.reduce({MapSet.new(), true}, fn hook, {keys, known?} ->
      case Assigns.on_mount_keys(hook) do
        {:ok, hook_keys} -> {MapSet.union(keys, hook_keys), known?}
        :unknown -> {keys, false}
      end
    end)
  end
end
