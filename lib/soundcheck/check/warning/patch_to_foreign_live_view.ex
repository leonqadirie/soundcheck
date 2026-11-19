defmodule Soundcheck.Check.Warning.PatchToForeignLiveView do
  use Soundcheck.Check,
    id: "SC701",
    base_priority: :high,
    category: :warning,
    confidence: :high,
    tier: :semantic,
    needs: [:live_modules, :routes],
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
      with the module that calls `push_patch`. When no live route that
      soundcheck read renders the calling LiveView, another LiveView may run
      its callbacks, so the finding is unverifiable and appears only under
      `strict`.
      """
    ]

  alias Soundcheck.Analysis.Navigation
  alias Soundcheck.Analysis.Routes
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, _params) do
    routes = Graph.routes(graph)
    routed = MapSet.new(routes, & &1.live_view)

    for {entry, :view} <- Graph.live_modules(graph),
        {path, span, anchor} <- Navigation.targets(graph, entry, :patch, [:server]),
        {:ok, segments} <- [Routes.segments(path)],
        [_ | _] = candidates <- [Routes.matching(routes, segments)],
        Enum.all?(candidates, &(&1.live_view != entry.name)) do
      targets = candidates |> Enum.map(&inspect(&1.live_view)) |> Enum.uniq() |> Enum.join(" or ")

      if MapSet.member?(routed, entry.name) do
        Diagnostic.new(
          __MODULE__,
          span,
          "This patch from `#{inspect(entry.name)}` goes to a route rendered by #{targets}; " <>
            "LiveView raises. Navigate instead.",
          anchor: anchor
        )
      else
        # LiveView compares the patch with the root view. No route renders
        # this module, so another LiveView may run its callbacks.
        Diagnostic.new(
          __MODULE__,
          span,
          "This patch from `#{inspect(entry.name)}` goes to a route rendered by #{targets}. " <>
            "No live route soundcheck read renders `#{inspect(entry.name)}`, so the patch " <>
            "is valid only if #{targets} runs this code.",
          anchor: anchor,
          resolution: {:unverifiable, :unrouted_live_view}
        )
      end
    end
  end
end
