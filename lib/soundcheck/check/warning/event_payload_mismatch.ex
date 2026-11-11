defmodule Soundcheck.Check.Warning.EventPayloadMismatch do
  use Soundcheck.Check,
    id: "SC108",
    base_priority: :normal,
    category: :warning,
    confidence: :medium,
    tier: :semantic,
    needs: [:routes, :render_index, :js_helpers],
    default: false,
    summary:
      "`phx-click` events whose `phx-value-*` and `JS.push` values lack a key every matching `handle_event/3` clause requires",
    param_defaults: [metadata_keys: []],
    explanations: [
      check: ~S"""
      Flags `phx-click` and `phx-click-away` events whose payload lacks a
      key that every matching `handle_event/3` clause requires. No clause
      matches the params, so the click raises `FunctionClauseError`.

      Before:

          <button phx-click="delete">Delete</button>

          def handle_event("delete", %{"id" => id}, socket)

      After:

          <button phx-click="delete" phx-value-id={post.id}>Delete</button>

      A click sends the element's `phx-value-*` attributes, its `value`
      when the element has one, and the `value:` map of a `JS.push`.
      Browsers lowercase attribute names, so `phx-value-postId` arrives as
      `"postid"`. The check reads the receivers' compiled clauses, so it
      routes events as `UnhandledEvent` (SC101) does and skips events no
      clause names. It stays silent when an element spreads attributes
      (`{@rest}`), when a `JS.push` value is not a literal map, and for
      receivers whose handlers `attach_hook/4` can intercept. Function
      component calls count as sending `value`, since the rendered element
      may carry one. List keys that a `LiveSocket` `metadata` callback adds
      to click events in `metadata_keys`.
      """,
      params: [
        metadata_keys: "Keys that `LiveSocket` `metadata` callbacks add to every click."
      ]
    ]

  alias Soundcheck.Analysis.Anchors
  alias Soundcheck.Analysis.Events
  alias Soundcheck.Analysis.Handlers
  alias Soundcheck.Beam.DebugInfo
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph
  alias Soundcheck.Heex.Node
  alias Soundcheck.Heex.Walker

  @click_attrs ["phx-click", "phx-click-away", "phx-target"]

  # Elements whose DOM node has a `value` property, which LiveView sends.
  @value_tags ~w(button data input li meter option output param progress select textarea)

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, params) do
    render_index = Graph.render_index(graph)
    js_helpers = Graph.js_helpers(graph)
    metadata = MapSet.new(Keyword.fetch!(params, :metadata_keys), &to_string/1)
    routes = Graph.routes(graph)

    for template <- graph.templates,
        %Node.Element{} = element <- Walker.elements(template.root),
        not Enum.any?(element.attrs, &(&1.name == :root)),
        click = %{element | attrs: Enum.filter(element.attrs, &(&1.name in @click_attrs))},
        %{event: {:literal, event}} = emitter <- Events.element_emitters(click, js_helpers),
        {:ok, sent} <- [payload(element, emitter, metadata)],
        {:ok, receivers} <- [Events.receivers(template, emitter, render_index)],
        receiver <- receivers,
        {:ok, missing} <- [missing(receiver, event, sent, routes)] do
      Diagnostic.new(__MODULE__, emitter.span, message(emitter, event, receiver, missing, sent),
        anchor: Anchors.for_template(graph, template, emitter.span)
      )
    end
  end

  # ── Payload ──

  # `{:ok, %{keys: keys, value?: maybe}}`, or `:error` when a push value
  # is not a literal map.
  defp payload(element, emitter, metadata) do
    phx_values =
      for %Node.Attr{name: "phx-value-" <> key} <- element.attrs, do: String.downcase(key)

    with {:ok, pushed} <- pushed_keys(emitter.value) do
      {:ok,
       %{
         keys: MapSet.new(phx_values ++ pushed) |> MapSet.union(metadata),
         value?: element.kind != :html or element.tag in @value_tags
       }}
    end
  end

  defp pushed_keys(nil), do: {:ok, []}

  defp pushed_keys({:%{}, _, pairs}) do
    keys = for {key, _value} <- pairs, is_atom(key) or is_binary(key), do: to_string(key)
    if length(keys) == length(pairs), do: {:ok, keys}, else: :error
  end

  defp pushed_keys(_dynamic), do: :error

  defp sends?(sent, key), do: key in sent.keys or (key == "value" and sent.value?)

  # ── Handler clauses ──

  # `{:ok, missing}` with the keys the closest clause lacks, when `module`
  # names `event` in some clause and no clause for it accepts `sent`.
  defp missing(module, event, sent, routes) do
    with {:ok, %{closed?: true}} <- Handlers.handler_set(module, :handle_event, routes),
         {:ok, clauses} <- DebugInfo.clauses(module, :handle_event, 3),
         [_ | _] = required <- required_keys(clauses, event),
         false <- Enum.any?(required, fn keys -> Enum.all?(keys, &sends?(sent, &1)) end) do
      {:ok, required |> Enum.map(&Enum.reject(&1, fn key -> sends?(sent, key) end)) |> closest()}
    else
      _handled_or_unknown -> :error
    end
  end

  # The keys each clause that can receive `event` requires; a clause whose
  # event pattern is not a literal can receive any event and requires
  # nothing as far as the check can tell.
  defp required_keys(clauses, event) do
    Enum.flat_map(clauses, fn
      {_meta, [^event, params, _socket], _guards, _body} -> [params_keys(params)]
      {_meta, [other, _params, _socket], _guards, _body} when is_binary(other) -> []
      {_meta, _args, _guards, _body} -> [[]]
    end)
  end

  defp params_keys(pattern) do
    for {key, _value} <- Handlers.map_pattern_pairs(pattern), is_binary(key), do: key
  end

  defp closest(missing), do: Enum.min_by(missing, &length/1)

  # ── Message ──

  defp message(emitter, event, receiver, missing, sent) do
    keys = Enum.map_join(missing, ", ", &inspect/1)

    ~s(`#{emitter.via}=#{inspect(event)}` sends no #{keys}, but every ) <>
      ~s|`handle_event(#{inspect(event)}, ...)` clause in `#{inspect(receiver)}` requires it, | <>
      "so the event raises." <> lowercase_hint(missing, sent)
  end

  defp lowercase_hint(missing, sent) do
    case Enum.find(missing, &(String.downcase(&1) in sent.keys)) do
      nil ->
        ""

      key ->
        " Browsers lowercase attribute names: `phx-value-#{key}` arrives as " <>
          "#{inspect(String.downcase(key))}."
    end
  end
end
