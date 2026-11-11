defmodule Soundcheck.Output.JSON do
  @moduledoc false
  # Renders findings as a JSON array, one object per finding, with every location.

  alias Soundcheck.Diagnostic
  alias Soundcheck.Span

  @spec render([Diagnostic.t()]) :: String.t()
  def render(diagnostics), do: Jason.encode!(Enum.map(diagnostics, &to_map/1), pretty: true)

  @doc "The JSON-ready map for one finding."
  @spec to_map(Diagnostic.t()) :: map()
  def to_map(%Diagnostic{} = d) do
    %{
      id: d.id,
      check: inspect(d.rule),
      message: d.message,
      suggestion: d.suggestion,
      confidence: d.confidence,
      resolution: resolution(d.resolution),
      location: span(d.primary),
      related: for({span, label} <- d.related, do: Map.put(span(span), :label, label))
    }
  end

  defp resolution(:resolved), do: "resolved"
  defp resolution({:unverifiable, reason}), do: "unverifiable: #{reason}"

  defp span(%Span{file: file, start: {line, column}, stop: {stop_line, stop_column}}),
    do: %{file: file, line: line, column: column, end_line: stop_line, end_column: stop_column}
end
