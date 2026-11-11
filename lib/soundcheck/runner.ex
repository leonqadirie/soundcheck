defmodule Soundcheck.Runner do
  @moduledoc false
  # Runs soundcheck outside Credo, for `mix soundcheck`.
  #
  # It parses the project's Elixir sources, builds the graph, and runs the
  # selected checks with their default parameters. Unverifiable findings are
  # kept only in strict mode. Findings come back sorted by location.

  alias Soundcheck.Baseline
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph
  alias Soundcheck.Graph.Input
  alias Soundcheck.Suppression

  @type result :: %{diagnostics: [Diagnostic.t()], graph: Graph.summary(), unparsable: [Path.t()]}

  @doc """
  Options:

    * `:paths` - globs of Elixir sources (default `["lib/**/*.ex"]`)
    * `:js_paths` - JavaScript directories (default: `Soundcheck.Graph.build/2`'s)
    * `:checks` - check modules to run (default `Soundcheck.Checks.defaults/0`)
    * `:check_params` - a map from check module to params that override its
      defaults (default `%{}`)
    * `:strict` - keep unverifiable findings (default `false`)
    * `:baseline` - a baseline file whose findings are dropped, or `nil`
      (default `Soundcheck.Baseline.default_path/0`)
  """
  @spec run(keyword()) :: result()
  def run(opts \\ []) do
    {graph_opts, opts} = Keyword.split(opts, [:js_paths])

    opts =
      Keyword.validate!(opts,
        paths: ["lib/**/*.ex"],
        checks: Soundcheck.Checks.defaults(),
        check_params: %{},
        strict: false,
        baseline: Baseline.default_path()
      )

    {inputs, unparsable} = Input.load(Keyword.fetch!(opts, :paths))
    graph = Graph.build(inputs, graph_opts)
    strict? = Keyword.fetch!(opts, :strict)
    overrides = Keyword.fetch!(opts, :check_params)

    diagnostics =
      for check <- Keyword.fetch!(opts, :checks),
          params = check_params(check, Map.get(overrides, check, []), strict?),
          diagnostic <- Diagnostic.normalize(check.analyze(graph, params)),
          Keyword.fetch!(params, :strict) or not Diagnostic.unverifiable?(diagnostic) do
        diagnostic
      end

    %{
      diagnostics:
        diagnostics
        |> Suppression.reject()
        |> Baseline.reject(baseline(Keyword.fetch!(opts, :baseline)))
        |> Enum.sort_by(&{&1.primary.file, &1.primary.start, &1.id}),
      graph: Graph.summary(graph),
      unparsable: unparsable
    }
  end

  # Defaults, then the project's params, then `--strict` on top.
  defp check_params(check, overrides, strict?) do
    check.param_defaults()
    |> Keyword.merge(overrides)
    |> Keyword.update(:strict, strict?, &(&1 or strict?))
  end

  defp baseline(nil), do: MapSet.new()
  defp baseline(path), do: Baseline.load(path)
end
