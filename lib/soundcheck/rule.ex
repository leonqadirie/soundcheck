defmodule Soundcheck.Rule do
  @moduledoc false
  # The analysis side of a soundcheck check.
  #
  # Each check module implements this behaviour alongside `Credo.Check`,
  # through `use Soundcheck.Check`. The rule id (`"SC203"`) is the Credo
  # check `:id`. `analyze/2` runs once per run over the whole project; the
  # Credo adapter files each diagnostic under its anchor file, and
  # `mix soundcheck` renders them directly.

  @type confidence :: Soundcheck.Diagnostic.confidence()
  @type tier :: :syntactic | :semantic

  @callback confidence() :: confidence()

  @callback tier() :: tier()

  @doc "Whether the check runs by default."
  @callback default?() :: boolean()

  @doc "One line on what the check catches, as the README's check table shows it."
  @callback summary() :: String.t()

  @callback analyze(Soundcheck.Graph.t(), params :: keyword()) :: [Soundcheck.Diagnostic.t()]
end
