defmodule Soundcheck.Output.SARIF do
  @moduledoc false
  # Renders findings as SARIF 2.1.0 for code-scanning tools.
  #
  # Unlike Credo's single-location SARIF, every result carries its related
  # locations, so a `.heex` or JavaScript location appears as itself. Columns
  # count Unicode codepoints (`columnKind: "unicodeCodePoints"`).
  # Unverifiable findings are `note`s; the rest are `warning`s.

  alias Soundcheck.Diagnostic
  alias Soundcheck.Span

  @spec render([Diagnostic.t()], [module()]) :: String.t()
  def render(diagnostics, checks) do
    %{
      "$schema" => "https://json.schemastore.org/sarif-2.1.0.json",
      "version" => "2.1.0",
      "runs" => [
        %{
          "tool" => %{
            "driver" => %{
              "name" => "soundcheck",
              "informationUri" => "https://hexdocs.pm/soundcheck",
              "version" => version(),
              "rules" => Enum.map(checks, &rule/1)
            }
          },
          "columnKind" => "unicodeCodePoints",
          "results" => Enum.map(diagnostics, &result/1)
        }
      ]
    }
    |> Jason.encode!(pretty: true)
  end

  defp rule(check) do
    %{
      "id" => check.id(),
      "name" => check |> Module.split() |> List.last(),
      "fullDescription" => %{"text" => explanation(check)},
      "properties" => %{"confidence" => check.confidence(), "tier" => check.tier()}
    }
  end

  defp explanation(check) do
    check.explanations() |> Keyword.get(:check, "") |> String.trim()
  end

  defp result(%Diagnostic{} = d) do
    %{
      "ruleId" => d.id,
      "level" => if(Diagnostic.unverifiable?(d), do: "note", else: "warning"),
      "message" => %{"text" => message(d)},
      "locations" => [location(d.primary)],
      "relatedLocations" =>
        d.related
        |> Enum.with_index(1)
        |> Enum.map(fn {{span, label}, index} ->
          span |> location() |> Map.merge(%{"id" => index, "message" => %{"text" => label}})
        end),
      "properties" => %{"confidence" => d.confidence, "resolution" => resolution(d.resolution)}
    }
  end

  defp message(%Diagnostic{message: message, suggestion: nil}), do: message

  defp message(%Diagnostic{message: message, suggestion: suggestion}),
    do: "#{message} #{suggestion}"

  defp resolution(:resolved), do: "resolved"
  defp resolution({:unverifiable, reason}), do: "unverifiable: #{reason}"

  defp location(%Span{file: file, start: {line, column}, stop: {stop_line, stop_column}}) do
    %{
      "physicalLocation" => %{
        "artifactLocation" => %{"uri" => file},
        "region" => %{
          "startLine" => line,
          "startColumn" => column,
          "endLine" => stop_line,
          "endColumn" => stop_column
        }
      }
    }
  end

  defp version do
    case Application.spec(:soundcheck, :vsn) do
      nil -> "0.0.0"
      vsn -> to_string(vsn)
    end
  end
end
