defmodule Soundcheck.Check.Warning.FormWithoutRecovery do
  use Soundcheck.Check,
    id: "SC803",
    base_priority: :normal,
    category: :warning,
    confidence: :medium,
    tier: :syntactic,
    default: false,
    summary:
      "`phx-submit` forms without an `id` or `phx-change`, whose input LiveView cannot restore after a reconnect",
    explanations: [
      check: """
      Flags `phx-submit` forms that LiveView cannot recover after a
      reconnect. When the socket drops (a deploy, a flaky network) and
      reconnects, LiveView restores a form's input by sending its values
      to the form's `phx-change` event, and it finds the form by `id`. A
      form without an `id`, or without `phx-change`, loses everything the
      user typed.

      Before:

          <.form for={@form} phx-submit="save">
            <.input field={@form[:title]} />
          </.form>

      After:

          <.form for={@form} id="post-form" phx-change="validate" phx-submit="save">
            <.input field={@form[:title]} />
          </.form>

      `phx-auto-recover` names another event for recovery and counts in
      place of `phx-change`; `phx-auto-recover="ignore"` opts a form out of
      recovery and silences the check. Forms with a dynamic attribute list
      (`<.form {@rest}>`) are skipped, because the list may carry both.
      """
    ]

  alias Soundcheck.Analysis.Anchors
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph
  alias Soundcheck.Heex.Node
  alias Soundcheck.Heex.Walker

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, _params) do
    for template <- graph.templates,
        %Node.Element{tag: tag} = form <- Walker.elements(template.root),
        tag in ["form", ".form", ".simple_form"],
        attrs = Map.new(form.attrs, &{&1.name, &1}),
        Map.has_key?(attrs, "phx-submit"),
        not Map.has_key?(attrs, :root),
        not opted_out?(attrs),
        missing = missing(attrs),
        missing != [],
        absent = Enum.join(missing, " and no ") do
      Diagnostic.new(
        __MODULE__,
        form.open_span,
        "This form has no #{absent}, so LiveView cannot restore its input after a reconnect.",
        suggestion: suggestion(missing),
        anchor: Anchors.for_template(graph, template, form.open_span)
      )
    end
  end

  defp opted_out?(%{"phx-auto-recover" => %Node.Attr{value: {:string, "ignore", _, _}}}), do: true

  defp opted_out?(_attrs), do: false

  defp missing(attrs) do
    id = if Map.has_key?(attrs, "id"), do: [], else: ["`id`"]

    recover =
      if Map.has_key?(attrs, "phx-change") or Map.has_key?(attrs, "phx-auto-recover"),
        do: [],
        else: ["`phx-change`"]

    id ++ recover
  end

  defp suggestion(["`id`"]), do: "Give it a stable `id`."

  defp suggestion(missing) do
    id = if "`id`" in missing, do: "a stable `id` and ", else: ""

    "Add #{id}a `phx-change` event (it can validate), or `phx-auto-recover=\"ignore\"` " <>
      "to opt out."
  end
end
