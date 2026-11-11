defmodule Soundcheck.Check.Refactor.FormForChangeset do
  use Soundcheck.Check,
    id: "SC801",
    base_priority: :normal,
    category: :refactor,
    confidence: :medium,
    tier: :syntactic,
    default: false,
    summary: "Forms built from a changeset assign instead of `to_form/2`",
    explanations: [
      check: """
      Flags forms built directly from a changeset assign
      (`<.form for={@changeset}>`) instead of from `to_form/2`. A changeset
      assign changes as a whole on every validation, so LiveView re-renders
      the entire form; a `Phoenix.HTML.Form` from `to_form/2` lets it track
      fields individually, and is what Phoenix's generators and `<.input>`
      expect.

      Before:

          assign(socket, :changeset, Accounts.change_user(user))

          <.form for={@changeset} phx-change="validate">

      After:

          assign(socket, :form, to_form(Accounts.change_user(user)))

          <.form for={@form} phx-change="validate">

      The check recognizes a changeset by name: an assign whose name ends in
      `changeset`.
      """
    ]

  alias Soundcheck.Analysis.Anchors
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph
  alias Soundcheck.Heex.Node
  alias Soundcheck.Heex.Walker

  @form_tags [".form", ".simple_form", "Phoenix.Component.form"]

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, _params) do
    for template <- graph.templates,
        %Node.Element{tag: tag, attrs: attrs} <- Walker.elements(template.root),
        tag in @form_tags,
        %Node.Attr{name: "for", value: {:expr, {:@, _, [{key, _, context}]}, _source, span}} <-
          attrs,
        is_atom(context),
        key |> Atom.to_string() |> String.ends_with?("changeset") do
      Diagnostic.new(
        __MODULE__,
        span,
        "`<#{tag} for={@#{key}}>` builds the form from a changeset; assign `to_form(changeset)` and pass that.",
        anchor: Anchors.for_template(graph, template, span)
      )
    end
  end
end
