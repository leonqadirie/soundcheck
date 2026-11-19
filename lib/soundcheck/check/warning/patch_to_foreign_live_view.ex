defmodule Soundcheck.Check.Warning.PatchToForeignLiveView do
  use Soundcheck.Check,
    id: "SC701",
    base_priority: :high,
    category: :warning,
    confidence: :high,
    tier: :semantic,
    needs: [:live_modules, :routes, :live_hosts],
    default: true,
    summary: "`push_patch` to a route another LiveView renders, which raises",
    explanations: [
      check: ~S"""
      Flags `push_patch` to a path whose live route renders a different
      LiveView. A patch keeps the current LiveView and only calls
      `handle_params/3`, so LiveView raises when the server pushes one that
      points elsewhere. Use `push_navigate` for another LiveView. A
      client-side patch (`<.link patch={...}>`, `JS.patch`) to another
      LiveView does not raise: LiveView falls back to navigating there.

      Before:

          # in MyAppWeb.PostLive.Index
          {:noreply, push_patch(socket, to: ~p"/users/#{user}")}

      After:

          {:noreply, push_navigate(socket, to: ~p"/users/#{user}")}

      Only literal paths and `~p` sigils are checked, and only in a
      LiveView's own functions. An interpolation
      inside `~p` matches any one route segment; one in a plain string
      matches any number of them, because the value can hold slashes. The
      check reports only when every matching live route renders another
      LiveView.

      LiveView compares the patch with the LiveView the router mounted, not
      with the module that calls `push_patch`. A routed LiveView that names
      the calling LiveView in its code counts as its host: it may delegate
      its callbacks to it or nest it with `live_render`.

      When a matching route renders a host, the check stays silent for a
      calling LiveView without a route of its own. For one that has a
      route the finding is unverifiable and appears only under `strict`:
      the patch is valid under the host and raises when the calling
      LiveView is the root view.

      The finding is also unverifiable when no live route that soundcheck
      read renders the calling LiveView, because a host that picks it from
      a registry or from configuration names nothing, and when the LiveView
      the patch goes to carries no readable debug info, because it may be a
      host. A calling LiveView with its own route and no host on the
      patch's route gets a resolved finding, although a host that does not
      name it directly, such as one that nests it through a component of
      another module, stays unseen.
      """
    ]

  alias Soundcheck.Analysis.LiveHosts
  alias Soundcheck.Analysis.Navigation
  alias Soundcheck.Analysis.Routes
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, _params) do
    routes = Graph.routes(graph)
    hosts = Graph.live_hosts(graph)

    for {entry, :view} <- Graph.live_modules(graph),
        {path, span, anchor} <- Navigation.targets(graph, entry, :patch, [:server]),
        {:ok, segments} <- [Routes.segments(path)],
        [_ | _] = candidates <- [Routes.matching(routes, segments)],
        targets = candidates |> Enum.map(& &1.live_view) |> Enum.uniq(),
        entry.name not in targets,
        {message, resolution} <- finding(hosts, entry.name, targets) do
      Diagnostic.new(__MODULE__, span, message, anchor: anchor, resolution: resolution)
    end
  end

  # LiveView compares the patch with the root view, which is the calling
  # module or a LiveView that runs its code. The hosts found may miss a
  # LiveView and may include one that only names the module, so a finding
  # is resolved only for a module with its own route and no sign of a host
  # on the patch's route: the patch raises whenever that module is the root.
  defp finding(hosts, module, targets) do
    from = "This patch from `#{inspect(module)}` goes to a route rendered by #{list(targets)}"
    routed? = LiveHosts.routed?(hosts, module)
    named = LiveHosts.hosts(hosts, module)
    hosting = Enum.filter(targets, &(&1 in named))
    unreadable = Enum.filter(targets, &LiveHosts.unreadable?(hosts, &1))

    cond do
      hosting != [] and not routed? ->
        []

      hosting != [] ->
        [
          {"#{from}. #{list(hosting)} names `#{inspect(module)}`: LiveView accepts the patch " <>
             "when #{list(hosting)} runs this code and raises when `#{inspect(module)}` is the " <>
             "root view.", {:unverifiable, :hosted_live_view}}
        ]

      not routed? ->
        [
          {"#{from}. No live route soundcheck read renders `#{inspect(module)}`" <>
             "#{named_by(named)}, so the patch is valid only if #{list(targets)} runs this code.",
           {:unverifiable, :unrouted_live_view}}
        ]

      unreadable != [] ->
        [
          {"#{from}. Soundcheck cannot read #{list(unreadable)}, which may run this code, " <>
             "so the patch may be valid.", {:unverifiable, :unreadable_host}}
        ]

      true ->
        [{"#{from}; LiveView raises. Navigate instead.", :resolved}]
    end
  end

  defp named_by([]), do: ""
  defp named_by(named), do: ", and #{list(named)}, which names it, renders another route"

  defp list(modules), do: Enum.map_join(modules, " or ", &inspect/1)
end
