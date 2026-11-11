defmodule Soundcheck.Check.Warning.PatchWithoutHandleParams do
  use Soundcheck.Check,
    id: "SC703",
    base_priority: :high,
    category: :warning,
    confidence: :high,
    tier: :semantic,
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
      the check reads the compiled module.
      """
    ]

  alias Soundcheck.Analysis.LiveModules
  alias Soundcheck.Analysis.MountHooks
  alias Soundcheck.Analysis.Navigation
  alias Soundcheck.Analysis.Routes
  alias Soundcheck.Beam.Introspect
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, _params) do
    routes = MountHooks.routes(graph)

    for {entry, :view} <- LiveModules.all(graph),
        {:ok, functions} <- [Introspect.functions(entry.name)],
        {:handle_params, 3} not in functions,
        {path, span, anchor} <- Navigation.targets(graph, entry, :patch),
        {:ok, segments} <- [Routes.segments(path)],
        Enum.any?(Routes.matching(routes, segments), &(&1.live_view == entry.name)) do
      Diagnostic.new(
        __MODULE__,
        span,
        "This patch returns to `#{inspect(entry.name)}`, which defines no " <>
          "`handle_params/3`; LiveView raises. Define `handle_params/3` or navigate instead.",
        anchor: anchor
      )
    end
  end
end
