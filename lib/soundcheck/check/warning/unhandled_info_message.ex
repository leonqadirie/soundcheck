defmodule Soundcheck.Check.Warning.UnhandledInfoMessage do
  use Soundcheck.Check,
    id: "SC107",
    base_priority: :high,
    category: :warning,
    confidence: :high,
    tier: :semantic,
    default: false,
    summary:
      "Messages a LiveView sends itself, or a LiveComponent sends its parent LiveView, with no matching `handle_info/2` clause",
    explanations: [
      check: """
      Flags messages a LiveView sends to itself (`send(self(), msg)`,
      `Process.send/3`, `Process.send_after/3`) that no `handle_info/2`
      clause accepts. LiveView crashes the process on an unhandled message.

      Before:

          def mount(_params, _session, socket) do
            if connected?(socket), do: Process.send_after(self(), :tick, 1000)
            {:ok, socket}
          end

      After:

          def handle_info(:tick, socket), do: {:noreply, update(socket, :now, &tick/1)}

      Only literal messages are checked: an atom, or a tuple tagged with an
      atom (`{:loaded, data}` matches a `{:loaded, _}` clause). A
      `handle_info(msg, socket)` catch-all accepts everything. A
      LiveComponent runs in its parent LiveView's process, so its messages
      to `self()` are checked against every LiveView that renders it.

      Handlers attached with `attach_hook/4` (in the module or its
      `on_mount` hooks) make the finding unverifiable; it appears only in
      strict mode.
      """,
      params: [
        strict: "Report unverifiable findings too."
      ]
    ]

  alias Soundcheck.Analysis.Components
  alias Soundcheck.Analysis.Events
  alias Soundcheck.Analysis.Handlers
  alias Soundcheck.Analysis.LiveModules
  alias Soundcheck.Analysis.MountHooks
  alias Soundcheck.Graph

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, _params) do
    render_index = Components.render_index(graph)
    routes = MountHooks.routes(graph)

    for {entry, kind} <- LiveModules.all(graph),
        {:ok, [_ | _] = sends} <- [Handlers.self_sends(entry.name)],
        receiver <- receivers(entry.name, kind, render_index),
        {:ok, handlers} <- [Handlers.handler_set(receiver, :handle_info, routes)],
        sent <- sends,
        not Handlers.handles?(handlers, sent.message) do
      LiveModules.unhandled(
        __MODULE__,
        entry,
        sent,
        handlers,
        message(entry, kind, sent, receiver)
      )
    end
  end

  # A LiveComponent whose parents do not resolve reports nothing.
  defp receivers(module, :view, _render_index), do: [module]

  defp receivers(module, :component, render_index) do
    case Events.parent_views(module, render_index) do
      {:ok, parents} -> parents
      {:unverifiable, _reason} -> []
    end
  end

  defp message(entry, :view, sent, _receiver) do
    "`#{sent.call}` sends `#{LiveModules.describe(sent.message)}` to this LiveView, " <>
      "but `#{inspect(entry.name)}` has no matching `handle_info/2` clause."
  end

  defp message(entry, :component, sent, receiver) do
    "`#{sent.call}` in LiveComponent `#{inspect(entry.name)}` sends " <>
      "`#{LiveModules.describe(sent.message)}` to its parent LiveView, but " <>
      "`#{inspect(receiver)}` has no matching `handle_info/2` clause."
  end
end
