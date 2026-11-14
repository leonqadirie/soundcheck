defmodule Soundcheck.Check.Warning.AssignSetOnlyWhenConnected do
  use Soundcheck.Check,
    id: "SC202",
    base_priority: :high,
    category: :warning,
    confidence: :high,
    tier: :semantic,
    needs: [:live_modules, :routes],
    default: true,
    summary:
      "Template reads of assigns `mount/3` sets only when connected, which crash the first, disconnected render",
    explanations: [
      check: """
      Flags template reads of assigns that `mount/3` sets only when
      `connected?(socket)` is true. LiveView renders every page twice: first
      over HTTP, disconnected, then over the websocket. The disconnected
      render raises `KeyError` on the missing assign, so the page never
      loads.

      Before:

          def mount(_params, _session, socket) do
            if connected?(socket),
              do: {:ok, assign(socket, :stats, Stats.load())},
              else: {:ok, socket}
          end

          def render(assigns), do: ~H"<p>{@stats.total}</p>"

      After:

          def mount(_params, _session, socket) do
            stats = if connected?(socket), do: Stats.load(), else: nil
            {:ok, assign(socket, :stats, stats)}
          end

      The check interprets `mount/3` once per context, following
      `if connected?(socket)`, its negations, and compounds such as
      `connected?(socket) and enabled?()`. Keys that `handle_params/3`
      or an `on_mount` hook assigns are never reported, because both run on
      the disconnected render too. When the disconnected path passes the
      socket to a function soundcheck does not model, the check makes no
      claim. When `handle_params/3` does, or an `on_mount` hook cannot be
      read, findings are unverifiable.
      """,
      params: [
        strict: "Report unverifiable findings too."
      ]
    ]

  alias Soundcheck.Analysis.Anchors
  alias Soundcheck.Analysis.Assigns
  alias Soundcheck.Analysis.Components
  alias Soundcheck.Analysis.MountHooks
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph
  alias Soundcheck.Heex.Reads

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, _params) do
    routes = Graph.routes(graph)

    for {entry, :view} <- Graph.live_modules(graph),
        {candidates, resolution} <- [candidates(entry, routes)],
        MapSet.size(candidates) > 0,
        template <- Components.render_templates(graph, entry.name),
        {:ok, render_keys} <- [Assigns.render_keys(graph, template)],
        read <- template |> Reads.assigns() |> Enum.uniq_by(& &1.key),
        MapSet.member?(candidates, read.key),
        not MapSet.member?(render_keys, read.key) do
      Diagnostic.new(
        __MODULE__,
        read.span,
        "`@#{read.key}` is read in `render/1`, but `mount/3` assigns `:#{read.key}` only when " <>
          "`connected?(socket)` is true: the first, disconnected render raises KeyError.",
        anchor: Anchors.for_template(graph, template, read.span),
        resolution: resolution
      )
    end
  end

  # Keys mount/3 may assign when connected but never when disconnected, minus
  # what handle_params/3 and on_mount hooks assign, with the resolution. A
  # disconnected mount that navigates away on every path never renders.
  defp candidates(entry, routes) do
    mount = Map.get(entry.functions, {:mount, 3}, [])
    connected = Assigns.mount(mount, true)
    disconnected = Assigns.mount(mount, false)

    if disconnected.open? or disconnected.halted? do
      {MapSet.new(), :resolved}
    else
      params = Assigns.any_path(Map.get(entry.functions, {:handle_params, 3}, []))
      {hook_keys, hooks_known?} = MountHooks.keys(entry.name, routes)

      keys =
        connected.may
        |> MapSet.difference(disconnected.may)
        |> MapSet.difference(params.may)
        |> MapSet.difference(hook_keys)

      resolution =
        cond do
          params.open? -> {:unverifiable, :open_handle_params}
          not hooks_known? -> {:unverifiable, :unreadable_on_mount}
          true -> :resolved
        end

      {keys, resolution}
    end
  end
end
