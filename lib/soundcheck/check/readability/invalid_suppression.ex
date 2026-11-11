defmodule Soundcheck.Check.Readability.InvalidSuppression do
  use Soundcheck.Check,
    id: "SC001",
    base_priority: :low,
    category: :readability,
    confidence: :high,
    tier: :syntactic,
    default: true,
    summary:
      "`soundcheck:disable-*` comments naming no rule or an unknown one; with `strict`, comments without a reason",
    explanations: [
      check: """
      Flags `soundcheck:disable-*` comments that suppress nothing: comments
      that name no rule, and selectors that match no soundcheck rule (a
      mistyped id such as `SC1010`, or a renamed check). With `strict: true`,
      also flags suppressions without a ` -- reason`.

      Before:

          # soundcheck:disable-next-line SC1O1
          <button phx-click="legacy">

      After:

          # soundcheck:disable-next-line SC101 -- pushed by the legacy widget
          <button phx-click="legacy">

      A selector is a rule id (`SC101`), a family wildcard (`SC1xx`), or a
      check's short name (`UnhandledEvent`). The check reads Elixir sources,
      `.heex` templates, and JavaScript files; findings in JavaScript appear
      only in `mix soundcheck`.
      """,
      params: [
        strict: "Also report suppressions without a ` -- reason`."
      ]
    ]

  alias Soundcheck.Analysis.Anchors
  alias Soundcheck.Analysis.Suggest
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph
  alias Soundcheck.Span
  alias Soundcheck.Suppression

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, params) do
    checks = checks()

    known =
      Enum.map(checks, & &1.id()) ++ Enum.map(checks, &(&1 |> Module.split() |> List.last()))

    templates =
      Map.new(for %{origin: :file} = template <- graph.templates, do: {template.file, template})

    for file <- files(graph),
        directive <- Suppression.file_directives(file),
        problem <- problems(directive, known, Keyword.fetch!(params, :strict)) do
      start = {directive.line, directive.column}
      span = Span.new(file, start, {directive.line, directive.column + directive.length})

      anchor =
        case templates do
          %{^file => template} -> Anchors.for_template(graph, template, span)
          _other -> span
        end

      Diagnostic.new(__MODULE__, span, problem, anchor: anchor)
    end
  end

  # Every check module in the application, read from its spec: the check
  # registry lists the checks, so checks cannot depend on it.
  defp checks do
    for module <- Application.spec(:soundcheck, :modules) || [],
        match?(["Soundcheck", "Check", _category, _name], Module.split(module)),
        do: module
  end

  defp files(graph) do
    heex = for %{origin: :file, file: file} <- graph.templates, do: file
    js = for %{file: file} <- graph.js, do: file
    Enum.uniq(Enum.map(graph.modules, & &1.file) ++ heex ++ js)
  end

  defp problems(%{selectors: []}, _known, _strict?),
    do: [
      "This suppression names no rule, so it suppresses nothing; add a rule id such as `SC101`."
    ]

  defp problems(directive, known, strict?) do
    unknown =
      for selector <- directive.selectors, not known?(selector, known) do
        hint =
          case Suggest.closest(selector, known) do
            nil -> ""
            suggestion -> " Did you mean `#{suggestion}`?"
          end

        "`#{selector}` matches no soundcheck rule, so this suppression does nothing for it.#{hint}"
      end

    missing_reason =
      if strict? and directive.reason == nil,
        do: ["This suppression gives no reason; add one after ` -- `."],
        else: []

    unknown ++ missing_reason
  end

  defp known?(selector, known) do
    selector in known or
      (selector =~ ~r/^SC\d*x+$/ and
         Enum.any?(known, &String.starts_with?(&1, String.trim_trailing(selector, "x"))))
  end
end
