defmodule Soundcheck.Graph.Current do
  @moduledoc false
  # This run's graph, for the Credo checks.
  #
  # `Soundcheck.Credo.BuildGraphTask` calls `prepare/2` with Credo's parsed
  # source files before any check runs. `get/1` returns that graph with the
  # links a check needs, and builds the graph from the Mix project's sources
  # when the task did not run (checks enabled without the plugin).
  #
  # Each link computes once per run, when the first check that needs it
  # asks; checks that ask meanwhile wait for that computation. Credo runs
  # its checks concurrently, so a check that needs no link, or a link
  # already computed, never waits for the others. The graph and each link
  # live in persistent terms, so checks read them without copying.

  alias Soundcheck.Graph
  alias Soundcheck.Graph.Input
  alias Soundcheck.Graph.Link
  alias Soundcheck.Once

  @doc "Returns this run's graph with the links in `needs`."
  @spec get([Graph.link()]) :: Graph.t()
  def get(needs) do
    graph = Once.run_shared({__MODULE__, :graph}, fn -> Graph.build(discover()) end)

    needs
    |> Enum.uniq()
    |> Enum.reduce(graph, fn link, acc ->
      Map.put(acc, link, Once.run_shared({__MODULE__, link}, fn -> Link.compute(link, graph) end))
    end)
  end

  @doc """
  Makes `inputs` this run's graph unless one exists already. `opts` go to
  `Soundcheck.Graph.build/2`.
  """
  @spec prepare([Input.t()], keyword()) :: Graph.t()
  def prepare(inputs, opts),
    do: Once.run_shared({__MODULE__, :graph}, fn -> Graph.build(inputs, opts) end)

  defp discover do
    {inputs, _unparsable} = Input.load(Input.default_globs())
    inputs
  end
end
