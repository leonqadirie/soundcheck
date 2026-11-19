defmodule Soundcheck.Check.Warning.PatchWithoutHandleParams do
  use Soundcheck.Check,
    id: "SC703",
    base_priority: :high,
    category: :warning,
    confidence: :high,
    tier: :semantic,
    needs: [:live_modules, :routes, :live_hosts],
    default: true,
    summary:
      "`push_patch`, `<.link patch>`, and `JS.patch` back to a LiveView that defines no `handle_params/3`, which raises",
    explanations: [
      check: ~S"""
      Flags `push_patch`, `<.link patch={...}>`, and `JS.patch` in a
      LiveView that defines no `handle_params/3`, when the path routes back
      to that LiveView. A patch keeps the LiveView and calls `handle_params/3`
      with the new URL, so LiveView raises `UndefinedFunctionError`.

      Before:

          # MyAppWeb.PostLive.Index defines mount/3 and render/1 only
          {:noreply, push_patch(socket, to: ~p"/posts?page=#{page}")}

      After:

          def handle_params(params, _uri, socket),
            do: {:noreply, assign(socket, :page, params["page"] || "1")}

      Paths resolve to routes as in `PatchToForeignLiveView` (SC701); a
      patch whose routes all render another LiveView never reaches this
      LiveView's `handle_params/3`, and a path the check cannot resolve is
      skipped. A `handle_params/3` injected by a `use` macro counts, because
      the check reads the compiled module. The finding is unverifiable when
      the LiveView or one of its `on_mount` hooks attaches a `handle_params`
      hook with `attach_hook/4`, because a hook that halts takes the
      callback's place.

      A routed LiveView that names the calling LiveView in its code counts
      as its host: it may delegate its callbacks to it or nest it with
      `live_render`, and LiveView then calls the host's `handle_params/3`.
      The check also flags a `push_patch` when a host renders a matching
      route and no LiveView that renders one defines `handle_params/3`.
      A `handle_params` hook on one of them makes that finding unverifiable
      too.
      """
    ]

  alias Soundcheck.Analysis.Handlers
  alias Soundcheck.Analysis.LiveHosts
  alias Soundcheck.Analysis.Navigation
  alias Soundcheck.Analysis.Routes
  alias Soundcheck.Beam.Introspect
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, _params) do
    routes = Graph.routes(graph)
    views = Graph.live_modules(graph)

    own(views, graph, routes) ++ hosted(views, graph, routes, Graph.live_hosts(graph))
  end

  # Patches back to the LiveView that calls them.
  defp own(views, graph, routes) do
    for {entry, :view} <- views,
        not handle_params?(entry.name),
        {path, span, anchor} <- Navigation.targets(graph, entry, :patch),
        {:ok, segments} <- [Routes.segments(path)],
        Enum.any?(Routes.matching(routes, segments), &(&1.live_view == entry.name)) do
      Diagnostic.new(
        __MODULE__,
        span,
        "This patch returns to `#{inspect(entry.name)}`, which defines no " <>
          "`handle_params/3`; LiveView raises. Define `handle_params/3` or navigate instead.",
        anchor: anchor,
        resolution: hook_resolution([entry.name], routes)
      )
    end
  end

  # Server patches to a host's route. The hosts found may miss or wrongly
  # include a LiveView, so the check reports only a patch that raises
  # whichever LiveView is the root: under a LiveView that renders none of
  # the matching routes LiveView rejects the patch, and none of those that
  # render one defines `handle_params/3`. A client patch does not qualify:
  # under a LiveView that renders none of the routes it navigates instead.
  defp hosted(views, graph, routes, hosts) do
    for {entry, :view} <- views,
        named = LiveHosts.hosts(hosts, entry.name),
        named != [],
        {path, span, anchor} <- Navigation.targets(graph, entry, :patch, [:server]),
        {:ok, segments} <- [Routes.segments(path)],
        [_ | _] = candidates <- [Routes.matching(routes, segments)],
        targets = candidates |> Enum.map(& &1.live_view) |> Enum.uniq(),
        entry.name not in targets,
        [_ | _] = rendering <- [Enum.filter(named, &(&1 in targets))],
        not Enum.any?(targets, &handle_params?/1) do
      Diagnostic.new(
        __MODULE__,
        span,
        "This patch from `#{inspect(entry.name)}` goes to a route rendered by " <>
          "#{Enum.map_join(rendering, " or ", &"`#{inspect(&1)}`")}, which names it and " <>
          "defines no `handle_params/3`; LiveView raises. Define `handle_params/3` there " <>
          "or navigate instead.",
        anchor: anchor,
        resolution: hook_resolution(targets, routes)
      )
    end
  end

  # A `handle_params` hook that halts keeps LiveView from calling the
  # callback, so the patch may be valid without one.
  defp hook_resolution(modules, routes) do
    case Enum.flat_map(modules, &Handlers.attach_hook_reasons(&1, :handle_params, routes)) do
      [] -> :resolved
      [reason | _] -> {:unverifiable, reason}
    end
  end

  # A module that cannot be loaded counts as defining it: the check cannot
  # tell.
  defp handle_params?(module) do
    case Introspect.functions(module) do
      {:ok, functions} -> {:handle_params, 3} in functions
      {:error, :not_loadable} -> true
    end
  end
end
