defmodule Soundcheck.Rule do
  @moduledoc false
  # The analysis side of a soundcheck check.
  #
  # Each check module implements this behaviour alongside `Credo.Check`,
  # through `use Soundcheck.Check`. The rule id (`"SC203"`) is the Credo
  # check `:id`. `analyze/2` runs once per run over the whole project; the
  # Credo adapter files each diagnostic under its anchor file, and
  # `mix soundcheck` renders them directly.
  #
  # Both run a check through `run/3` and filter its findings through
  # `drop_silenced/3`, so Credo and `mix soundcheck` report the same ones.

  alias Soundcheck.Baseline
  alias Soundcheck.Diagnostic
  alias Soundcheck.Suppression

  @type confidence :: Soundcheck.Diagnostic.confidence()
  @type tier :: :syntactic | :semantic

  @callback confidence() :: confidence()

  @callback tier() :: tier()

  @doc "Whether the check runs by default."
  @callback default?() :: boolean()

  @doc "One line on what the check catches, as the README's check table shows it."
  @callback summary() :: String.t()

  @callback analyze(Soundcheck.Graph.t(), params :: keyword()) :: [Soundcheck.Diagnostic.t()]

  @doc """
  Runs `check` over `graph` and returns its diagnostics without duplicates,
  sorted by location. `params` must hold `:strict`; unverifiable
  diagnostics are kept only when it is `true`.
  """
  @spec run(module(), Soundcheck.Graph.t(), keyword()) :: [Diagnostic.t()]
  def run(check, graph, params) do
    strict? = Keyword.fetch!(params, :strict)

    graph
    |> check.analyze(params)
    |> Diagnostic.normalize()
    |> Enum.reject(&(Diagnostic.unverifiable?(&1) and not strict?))
  end

  @doc """
  Drops the diagnostics a `soundcheck:disable-*` comment suppresses, then
  those whose fingerprint is in `baseline`. `load` returns the suppression
  directives of a file.

  Suppression comes first: a fingerprint counts a finding's position among
  identical findings in its file, and a baseline records that count
  without the suppressed ones.
  """
  @spec drop_silenced(
          [Diagnostic.t()],
          MapSet.t(String.t()),
          (Path.t() -> [Suppression.directive()])
        ) :: [Diagnostic.t()]
  def drop_silenced(diagnostics, baseline, load \\ &Suppression.file_directives/1) do
    diagnostics
    |> Suppression.reject(load)
    |> Baseline.reject(baseline)
  end
end
