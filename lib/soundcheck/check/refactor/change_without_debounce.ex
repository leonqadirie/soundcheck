defmodule Soundcheck.Check.Refactor.ChangeWithoutDebounce do
  use Soundcheck.Check,
    id: "SC802",
    base_priority: :low,
    category: :refactor,
    confidence: :medium,
    tier: :syntactic,
    default: false,
    summary: "Text inputs in `phx-change` forms without `phx-debounce`",
    param_defaults: [input_types: ["text", "search", "email", "textarea", "url", "tel"]],
    explanations: [
      check: """
      Flags text-like inputs in a form with `phx-change` that set no
      `phx-debounce`. Without it, every keystroke sends a change event to
      the server and re-runs validation.

      Before:

          <.form for={@form} phx-change="search">
            <.input field={@form[:q]} type="search" />
          </.form>

      After:

          <.input field={@form[:q]} type="search" phx-debounce="300" />

      Inputs count as text-like when their `type` is in `input_types`, or
      when an `<.input>` component sets no type (it defaults to `text`).
      `<textarea>` always counts. A `phx-debounce` or `phx-throttle` on the
      input or on the form silences the check.
      """,
      params: [
        input_types: "Input types that count as text-like."
      ]
    ]

  alias Soundcheck.Analysis.Anchors
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph
  alias Soundcheck.Heex.Node
  alias Soundcheck.Heex.Walker

  @rate_limits ["phx-debounce", "phx-throttle"]

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, params) do
    for template <- graph.templates,
        %Node.Element{} = form <- Walker.elements(template.root),
        form?(form),
        attr?(form, "phx-change"),
        not Enum.any?(@rate_limits, &attr?(form, &1)),
        input <- Walker.elements(form.children),
        text_input?(input, Keyword.fetch!(params, :input_types)),
        not Enum.any?(@rate_limits, &attr?(input, &1)) do
      Diagnostic.new(
        __MODULE__,
        input.open_span,
        "This input sends a change event on every keystroke; add `phx-debounce`.",
        anchor: Anchors.for_template(graph, template, input.open_span)
      )
    end
  end

  defp form?(%Node.Element{tag: tag}), do: tag in ["form", ".form", ".simple_form"]

  defp text_input?(%Node.Element{kind: :html, tag: "textarea"}, _types), do: true

  defp text_input?(%Node.Element{kind: :html, tag: "input"} = input, types),
    do: type(input, "text") in types

  defp text_input?(%Node.Element{tag: ".input"} = input, types), do: type(input, "text") in types
  defp text_input?(_element, _types), do: false

  # A literal type, or `fallback` when none is set; a dynamic type is never
  # text-like.
  defp type(%Node.Element{attrs: attrs}, fallback) do
    case Enum.find(attrs, &(&1.name == "type")) do
      nil -> fallback
      %Node.Attr{value: {:string, type, _, _}} -> type
      _dynamic -> nil
    end
  end

  defp attr?(%Node.Element{attrs: attrs}, name), do: Enum.any?(attrs, &(&1.name == name))
end
