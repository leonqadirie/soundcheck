defmodule Soundcheck.Credo.BuildGraphTask do
  @moduledoc false
  # Credo pipeline task prepended to the `:run_analysis` group of the
  # `suggest` and `diff` commands by `Soundcheck.init/1`. It builds the run's
  # graph from the source files Credo already parsed, before any check runs,
  # so checks never race to build it. Checks still build the graph lazily
  # when this task did not run. The task records a graph summary in the
  # exec assign "soundcheck.graph".
  #
  # Credo's default config also parses a project's tests. The graph leaves
  # out the files under the plugin's `graph_excluded_paths` param (default:
  # test directories), so it holds the application sources `mix soundcheck`
  # reads by default. A LiveView in `test/support` that renders a component
  # would otherwise receive that component's events.
  #
  # The param differs from a check's `excluded_paths`: a file left out of
  # the graph gets no findings and influences none, while a file a check
  # excludes stays in the graph and only goes unreported by that check.

  use Credo.Execution.Task

  alias Credo.Execution
  alias Credo.SourceFile
  alias Soundcheck.Graph
  alias Soundcheck.Graph.Input
  alias Soundcheck.PathFilter

  @impl true
  def call(exec, opts) do
    plugin = Keyword.fetch!(opts, :plugin)

    excluded_paths =
      case Execution.get_plugin_param(exec, plugin, :graph_excluded_paths) do
        nil -> PathFilter.default_excluded_paths()
        paths -> paths
      end

    graph_opts =
      case Execution.get_plugin_param(exec, plugin, :js_paths) do
        nil -> []
        js_paths -> [js_paths: js_paths]
      end

    graph =
      exec
      |> Execution.get_source_files()
      |> inputs(excluded_paths)
      |> Graph.Current.prepare(graph_opts)

    Execution.put_assign(exec, "soundcheck.graph", Graph.summary(graph))
  end

  @doc """
  Streams graph inputs from successfully parsed files outside `excluded_paths`.
  This lets graph workers consume ASTs without first copying the entire
  source set out of Credo's cache.
  """
  @spec inputs([SourceFile.t()], [Regex.t() | String.t()]) :: Enumerable.t()
  def inputs(source_files, excluded_paths) do
    source_files
    |> Stream.filter(fn
      %SourceFile{status: :valid, filename: filename} ->
        not PathFilter.excluded?(filename, excluded_paths)

      _source_file ->
        false
    end)
    |> Stream.map(fn %SourceFile{filename: filename} = source_file ->
      %Input{
        file: filename,
        source: SourceFile.source(source_file),
        ast: SourceFile.ast(source_file)
      }
    end)
  end
end
