defmodule Soundcheck.Check.Design.UnusedHook do
  use Soundcheck.Check,
    id: "SC1002",
    base_priority: :low,
    category: :design,
    confidence: :medium,
    tier: :syntactic,
    default: false,
    summary:
      "Hooks registered with `LiveSocket` that no template uses; Credo reports these against the JavaScript file",
    explanations: [
      check: """
      Flags hooks registered with `LiveSocket` that no template references
      with `phx-hook`: dead JavaScript left behind after a template change.

      Before:

          Hooks.Legacy = {mounted() { ... }}   // no phx-hook="Legacy" anywhere

      After: delete the hook, or reference it from a template.

      The check reports nothing when any template uses a dynamic
      `phx-hook={...}`, which could name any hook. Colocated hooks are never
      reported: they live in the template that uses them.

      The finding's only location is in JavaScript. Credo reports it against
      the JavaScript file, without a line number; the message starts with
      `file:line:column`. `# credo:disable` comments cannot reach a JavaScript
      file, so silence a finding with `// soundcheck:disable-next-line SC1002`.
      """
    ]

  alias Soundcheck.Analysis.Hooks
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, _params) do
    usages = Hooks.usages(graph)

    if Enum.any?(usages, &(&1.name == :dynamic)) do
      []
    else
      used = MapSet.new(usages, & &1.name)

      for {name, {:socket, facts, ref}} <- Hooks.registry(graph).names,
          not MapSet.member?(used, name),
          span = definition_span(facts, ref) do
        Diagnostic.new(
          __MODULE__,
          span,
          "Hook `#{name}` is registered with `LiveSocket`, but no template uses `phx-hook=\"#{name}\"`.",
          anchor: nil
        )
      end
    end
  end

  defp definition_span(facts, {:object, id}), do: facts.objects[id].span

  defp definition_span(facts, _ref) do
    case facts.live_sockets do
      [socket | _] -> socket.span
      [] -> nil
    end
  end
end
