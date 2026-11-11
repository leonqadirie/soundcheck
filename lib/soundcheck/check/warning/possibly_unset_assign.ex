defmodule Soundcheck.Check.Warning.PossiblyUnsetAssign do
  use Soundcheck.Check,
    id: "SC201",
    base_priority: :high,
    category: :warning,
    confidence: :medium,
    tier: :semantic,
    needs: [:live_modules, :routes],
    default: false,
    summary:
      "Template reads of assigns `mount/3` does not set on every path before the first render",
    param_defaults: [
      assume_set: [:current_user, :current_scope, :flash, :live_action, :page_title]
    ],
    explanations: [
      check: """
      Flags template reads of assigns that `mount/3` does not set on every
      path before the first render. LiveView raises `KeyError` on the first
      render that reaches such a read.

      Before:

          def mount(_params, _session, socket), do: {:ok, socket}

          def handle_event("refresh", _params, socket),
            do: {:noreply, assign(socket, :stats, Stats.load())}

          def render(assigns), do: ~H"<p>{@stats.total}</p>"

      After:

          def mount(_params, _session, socket), do: {:ok, assign(socket, :stats, nil)}

          def render(assigns), do: ~H"<p :if={@stats}>{@stats.total}</p>"

      The check follows `mount/3` in both the disconnected and the
      connected context. A key counts as set before the first render when
      `mount/3` sets it on every path, when `handle_params/3` or an
      `on_mount` hook may set it, or when it is listed in `assume_set`. Only
      reads that run on every render count: reads inside `:if` elements,
      EEx `if`/`case`/`for` blocks, and slots are skipped. Keys set only
      when connected are left to `AssignSetOnlyWhenConnected` (SC202).

      When `mount/3` passes the socket to a function soundcheck does not
      model, the check makes no claim. When `handle_params/3` does, or an
      `on_mount` hook cannot be read, findings are unverifiable.
      """,
      params: [
        assume_set: "Keys the team's conventions guarantee before the first render.",
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
  def analyze(%Graph{} = graph, params) do
    routes = Graph.routes(graph)
    assumed = MapSet.new(Keyword.fetch!(params, :assume_set))

    for {entry, :view} <- Graph.live_modules(graph),
        {:ok, guaranteed, resolution} <- [guaranteed(entry, routes, assumed)],
        template <- Components.render_templates(graph, entry.name),
        {:ok, render_keys} <- [Assigns.render_keys(graph, template)],
        read <- template |> Reads.unconditional() |> Enum.uniq_by(& &1.key),
        not MapSet.member?(render_keys, read.key),
        unset?(read.key, guaranteed) do
      Diagnostic.new(
        __MODULE__,
        read.span,
        "`@#{read.key}` is read on every render of `render/1`, but no path through `mount/3` " <>
          "is guaranteed to assign `:#{read.key}` before the first render.",
        anchor: Anchors.for_template(graph, template, read.span),
        resolution: resolution
      )
    end
  end

  # A key read on the first render must be guaranteed in both contexts. Keys
  # set only when connected are SC202's.
  defp unset?(key, guaranteed) do
    not MapSet.member?(guaranteed.connected_only, key) and
      not (MapSet.member?(guaranteed.disconnected, key) and
             MapSet.member?(guaranteed.connected, key))
  end

  # Per context, the keys guaranteed before the first render: what mount/3
  # sets on every path that renders, plus what handle_params/3, on_mount
  # hooks, or the team's conventions may set. A context whose every mount
  # path navigates away never renders. Keys render/1 sets before a template
  # count per template.
  defp guaranteed(entry, routes, assumed) do
    mount = Map.get(entry.functions, {:mount, 3}, [])
    disconnected = Assigns.mount(mount, false)
    connected = Assigns.mount(mount, true)

    if disconnected.open? or connected.open? or disconnected.halted? or connected.halted? do
      :skip
    else
      params = Assigns.any_path(Map.get(entry.functions, {:handle_params, 3}, []))
      {hook_keys, hooks_known?} = MountHooks.keys(entry.name, routes)
      elsewhere = params.may |> MapSet.union(hook_keys) |> MapSet.union(assumed)

      guaranteed = %{
        disconnected: MapSet.union(disconnected.must, elsewhere),
        connected: MapSet.union(connected.must, elsewhere),
        connected_only: MapSet.difference(connected.may, disconnected.may)
      }

      {:ok, guaranteed, resolution(params, hooks_known?)}
    end
  end

  defp resolution(params, hooks_known?) do
    cond do
      params.open? -> {:unverifiable, :open_handle_params}
      not hooks_known? -> {:unverifiable, :unreadable_on_mount}
      true -> :resolved
    end
  end
end
