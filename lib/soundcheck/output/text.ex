defmodule Soundcheck.Output.Text do
  @moduledoc false
  # Renders findings for the terminal, with every location they involve:
  #
  #     SC101 warning: `phx-click="sav"` has no matching `handle_event/3` clause in `MyAppWeb.PostLive`.
  #       --> lib/my_app_web/live/post_live.ex:14:23
  #        |
  #     14 |     <button phx-click="sav">Save</button>
  #        |                       ^^^
  #        = help: Did you mean "save"?

  alias Soundcheck.Diagnostic
  alias Soundcheck.Span

  @spec render([Diagnostic.t()]) :: String.t()
  def render(diagnostics) do
    sources = diagnostics |> Enum.flat_map(&files/1) |> Enum.uniq() |> Map.new(&{&1, lines(&1)})

    body = Enum.map_join(diagnostics, "\n", &diagnostic(&1, sources))
    body <> summary(diagnostics)
  end

  defp diagnostic(%Diagnostic{} = d, sources) do
    header = "#{d.id} #{category(d)}: #{d.message}#{resolution(d)}\n"

    related =
      Enum.map_join(d.related, fn {span, label} ->
        "   = note: #{label}\n" <> location(span, sources)
      end)

    help = if d.suggestion, do: "   = help: #{d.suggestion}\n", else: ""
    header <> location(d.primary, sources) <> help <> related
  end

  defp location(%Span{file: file, start: {line, column}} = span, sources) do
    gutter = String.duplicate(" ", String.length(Integer.to_string(line)))

    snippet =
      sources
      |> Map.get(file, %{})
      |> Map.get(line)
      |> case do
        nil ->
          ""

        text ->
          "#{gutter} |\n#{line} | #{text}\n#{gutter} | #{String.duplicate(" ", column - 1)}#{carets(span, text)}\n"
      end

    "#{gutter}--> #{file}:#{line}:#{column}\n" <> snippet
  end

  defp carets(%Span{start: {line, column}, stop: {stop_line, stop_column}}, text) do
    width =
      if stop_line == line,
        do: max(stop_column - column, 1),
        else: max(String.length(text) - column + 1, 1)

    String.duplicate("^", width)
  end

  defp resolution(%Diagnostic{resolution: {:unverifiable, reason}}),
    do: " (unverifiable: #{reason})"

  defp resolution(_diagnostic), do: ""

  defp category(%Diagnostic{rule: rule}), do: rule.category()

  defp files(%Diagnostic{primary: primary, related: related}),
    do: [primary.file | Enum.map(related, fn {span, _label} -> span.file end)]

  defp lines(file) do
    case File.read(file) do
      {:ok, source} ->
        source
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Map.new(fn {text, n} -> {n, text} end)

      {:error, _reason} ->
        %{}
    end
  end

  defp summary(diagnostics) do
    unverifiable = Enum.count(diagnostics, &Diagnostic.unverifiable?/1)
    findings = length(diagnostics) - unverifiable

    "\n#{findings} #{plural(findings, "finding")}" <>
      if(unverifiable > 0, do: ", #{unverifiable} unverifiable", else: "") <> "\n"
  end

  defp plural(1, word), do: word
  defp plural(_count, word), do: word <> "s"
end
