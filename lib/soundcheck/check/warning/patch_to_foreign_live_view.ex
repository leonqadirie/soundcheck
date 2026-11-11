defmodule Soundcheck.Check.Warning.PatchToForeignLiveView do
  use Soundcheck.Check,
    id: "SC701",
    base_priority: :high,
    category: :warning,
    confidence: :high,
    tier: :semantic,
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
      """
    ]

  alias Soundcheck.Analysis.LiveModules
  alias Soundcheck.Analysis.MountHooks
  alias Soundcheck.Analysis.Navigation
  alias Soundcheck.Analysis.Routes
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, _params) do
    routes = MountHooks.routes(graph)

    for {entry, :view} <- LiveModules.all(graph),
        {path, span, anchor} <- Navigation.targets(graph, entry, :patch, [:server]),
        {:ok, segments} <- [Routes.segments(path)],
        [_ | _] = candidates <- [Routes.matching(routes, segments)],
        Enum.all?(candidates, &(&1.live_view != entry.name)) do
      targets = candidates |> Enum.map(&inspect(&1.live_view)) |> Enum.uniq() |> Enum.join(" or ")

      Diagnostic.new(
        __MODULE__,
        span,
        "This patch from `#{inspect(entry.name)}` goes to a route rendered by #{targets}; " <>
          "LiveView raises. Navigate instead.",
        anchor: anchor
      )
    end
  end
end
