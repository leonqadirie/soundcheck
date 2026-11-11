defmodule Soundcheck.Analysis.MountHooks do
  @moduledoc false
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
end
