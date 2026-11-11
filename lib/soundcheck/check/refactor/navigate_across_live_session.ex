defmodule Soundcheck.Check.Refactor.NavigateAcrossLiveSession do
  use Soundcheck.Check,
    id: "SC702",
    base_priority: :low,
    category: :refactor,
    confidence: :low,
    tier: :semantic,
    default: false,
    summary:
      "`push_navigate`, `<.link navigate>`, and `JS.navigate` into another live_session, which reloads the page",
    param_defaults: [ignore_sessions: []],
    explanations: [
      check: ~S"""
      Flags `push_navigate`, `<.link navigate={...}>`, and `JS.navigate` to
      a route in a
      different `live_session` than every route of the current LiveView.
      LiveView navigates over the socket only within one live_session;
      across sessions it falls back to a full page reload, which drops the
      socket and reruns the plug pipeline and both mounts.

      Before:

          # in MyAppWeb.HomeLive, in live_session :public
          <.link navigate={~p"/admin"}>Admin</.link>

      After, when the reload is intended:

          <.link href={~p"/admin"}>Admin</.link>

      Or move both routes into one live_session when they share their
      `on_mount` hooks and layout.

      Only literal paths and `~p` sigils are checked. Interpolated segments
      match any route segment; the check reports only when every matching
      route sits in another session. `ignore_sessions` lists session names
      to skip as origin or target.
      """,
      params: [
        ignore_sessions: "live_session names (atoms) to skip as origin or target."
      ]
    ]

  alias Soundcheck.Analysis.LiveModules
  alias Soundcheck.Analysis.MountHooks
  alias Soundcheck.Analysis.Navigation
  alias Soundcheck.Analysis.Routes
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, params) do
    routes =
      Enum.reject(
        MountHooks.routes(graph),
        &(&1.live_session in Keyword.fetch!(params, :ignore_sessions))
      )

    for {entry, :view} <- LiveModules.all(graph),
        origin = sessions(routes, &(&1.live_view == entry.name)),
        origin != [],
        {path, span, anchor} <- Navigation.targets(graph, entry, :navigate),
        {:ok, segments} <- [Routes.segments(path)],
        [_ | _] = candidates <- [Routes.matching(routes, segments)],
        targets = sessions(candidates, fn _route -> true end),
        Enum.all?(targets, &(&1 not in origin)) do
      Diagnostic.new(
        __MODULE__,
        span,
        "This navigation from live_session #{list(origin)} goes to live_session #{list(targets)}, " <>
          "so LiveView reloads the full page; use `href` to make that explicit, " <>
          "or move the routes into one live_session.",
        anchor: anchor
      )
    end
  end

  defp sessions(routes, filter),
    do: routes |> Enum.filter(filter) |> Enum.map(& &1.live_session) |> Enum.uniq()

  defp list(sessions), do: Enum.map_join(sessions, " or ", &inspect/1)
end
