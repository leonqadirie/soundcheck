defmodule Soundcheck.Credo.BuildGraphTask do
  @moduledoc false
  # Credo pipeline task prepended to the `:run_analysis` group of the
  # `suggest` and `diff` commands by `Soundcheck.init/1`. It builds the run's
  # graph from the source files Credo already parsed, before any check runs,
  # so checks never race to build it. Checks still build the graph lazily
  # when this task did not run. The task records a graph summary in the
  # exec assign "soundcheck.graph".

  use Credo.Execution.Task

  alias Credo.Execution
  alias Credo.SourceFile
  alias Soundcheck.Graph
  alias Soundcheck.Graph.Input

  @impl true
  def call(exec, opts) do
    inputs =
      for %SourceFile{status: :valid} = source_file <- Execution.get_source_files(exec) do
        %Input{
          file: source_file.filename,
          source: SourceFile.source(source_file),
          ast: SourceFile.ast(source_file)
        }
      end

    graph_opts =
      case Execution.get_plugin_param(exec, Keyword.fetch!(opts, :plugin), :js_paths) do
        nil -> []
        js_paths -> [js_paths: js_paths]
      end

    graph = Graph.Current.prepare(inputs, graph_opts)
    Execution.put_assign(exec, "soundcheck.graph", Graph.summary(graph))
  end
end
