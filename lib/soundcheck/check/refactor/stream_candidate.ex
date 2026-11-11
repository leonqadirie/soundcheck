defmodule Soundcheck.Check.Refactor.StreamCandidate do
  use Soundcheck.Check,
    id: "SC307",
    base_priority: :low,
    category: :refactor,
    confidence: :low,
    tier: :syntactic,
    default: false,
    summary: "List assigns grown one item at a time and rendered with `:for`",
    explanations: [
      check: """
      Flags list assigns that handlers grow one item at a time and the
      template renders with `:for`. The LiveView keeps the whole list in
      memory and resends every item whenever it changes; a stream keeps no
      items on the server and sends only the new one.

      Before:

          def handle_info({:new_message, message}, socket) do
            {:noreply, update(socket, :messages, &(&1 ++ [message]))}
          end

          <div :for={message <- @messages}>{message.body}</div>

      After:

          def handle_info({:new_message, message}, socket) do
            {:noreply, stream_insert(socket, :messages, message)}
          end

          <div id="messages" phx-update="stream">
            <div :for={{id, message} <- @streams.messages} id={id}>{message.body}</div>
          </div>

      A write counts as growing the list when `update/3` gets a function
      that appends or prepends to its argument (`&(&1 ++ [x])`,
      `&[x | &1]`), or `assign/3` gets an append or prepend to
      `socket.assigns.key`.
      """
    ]

  alias Soundcheck.Analysis.AssignUse
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph
  alias Soundcheck.Span

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, _params) do
    for %{kind: kind} = entry <- graph.modules,
        kind in [:live_view, :live_component],
        looped = AssignUse.for_sources(graph, entry),
        MapSet.size(looped) > 0,
        write <- entry |> AssignUse.writes() |> Enum.filter(&grows?/1) |> Enum.uniq_by(& &1.key),
        write.key in looped do
      stop = {write.line, write.column + String.length(Atom.to_string(write.call))}
      span = Span.new(entry.file, {write.line, write.column}, stop)

      Diagnostic.new(
        __MODULE__,
        span,
        "`#{inspect(write.key)}` grows one item at a time and renders with `:for`; " <>
          "a stream (`stream_insert/4`) would keep it off the server."
      )
    end
  end

  defp grows?(%{call: :update, value: {:&, _, [body]}}),
    do: extends?(body, &match?({:&, _, [1]}, &1))

  defp grows?(%{call: :update, value: {:fn, _, [{:->, _, [[{name, _, context}], body]}]}})
       when is_atom(name) and is_atom(context),
       do: extends?(body, &match?({^name, _, ctx} when is_atom(ctx), &1))

  defp grows?(%{call: :assign, key: key, value: value}),
    do:
      extends?(
        value,
        &match?({{:., _, [{{:., _, [_socket, :assigns]}, _, []}, ^key]}, _, []}, &1)
      )

  defp grows?(_write), do: false

  # Whether `ast` appends to or prepends onto an operand `list?` accepts.
  defp extends?(ast, list?) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {:++, _, [left, right]} -> list?.(left) or list?.(right)
      [{:|, _, [_head, tail]}] -> list?.(tail)
      _node -> false
    end)
  end
end
