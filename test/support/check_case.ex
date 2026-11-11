defmodule Soundcheck.CheckCase do
  @moduledoc false
  # Helpers for rule tests: build a graph from source strings and run a
  # rule's analysis directly, or run the check through Credo's `run/2`.
  #
  # Tests run async by default. `analyze/4` passes its own graph to the
  # rule, and every run-cache entry besides the run's graph is a pure
  # function of its key (a compiled fixture module), so concurrent tests
  # share those entries safely. A test that sets the run's graph
  # (`run_check/4`, `Soundcheck.Graph.prepare/2`) must pass `async: false`,
  # which also empties the cache before each test.

  alias Soundcheck.Cache
  alias Soundcheck.Graph
  alias Soundcheck.Graph.Input

  defmacro __using__(opts) do
    async? = Keyword.get(opts, :async, true)

    quote do
      use ExUnit.Case, async: unquote(async?)

      import Soundcheck.CheckCase

      if not unquote(async?) do
        setup do
          Cache.clear()
          :ok
        end
      end
    end
  end

  @doc "Parses `sources` (`{file, source}` pairs or one source) into graph inputs."
  def inputs(sources) do
    for {file, source} <- List.wrap(normalize(sources)) do
      {:ok, input} = Input.parse(file, source)
      input
    end
  end

  defp normalize(source) when is_binary(source), do: [{"lib/demo.ex", source}]
  defp normalize(sources), do: sources

  @doc """
  Runs `check`'s analysis over a graph built from `sources`. `graph_opts`
  go to `Soundcheck.Graph.build/2` (default: no JavaScript).
  """
  def analyze(check, sources, params \\ [], graph_opts \\ []) do
    graph = Graph.build(inputs(sources), Keyword.merge([js_paths: []], graph_opts))
    params = Keyword.merge(check.param_defaults(), params)
    graph |> check.analyze(params) |> Soundcheck.Diagnostic.normalize()
  end

  @doc "Runs `check` through Credo's `run/2` on the file `file` of `sources`."
  def run_check(check, sources, file \\ "lib/demo.ex", params \\ []) do
    inputs = inputs(sources)
    Graph.prepare(inputs, js_paths: [])
    %{source: source} = Enum.find(inputs, &(&1.file == file))
    check.run(Credo.SourceFile.parse(source, file), params)
  end
end
