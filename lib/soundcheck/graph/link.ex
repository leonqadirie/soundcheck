defmodule Soundcheck.Graph.Link do
  @moduledoc false
  # Adds the links between files that several rules share to a graph built
  # by `Soundcheck.Graph.build/2`.
  #
  # Each link reads compiled modules or walks every module, so a run
  # computes each one once instead of once per check that needs it:
  # `mix soundcheck` links its checks' needs up front through `link/2`, and
  # `Soundcheck.Graph.Current` computes each link on first need for Credo's
  # concurrent checks.

  alias Soundcheck.Analysis.Components
  alias Soundcheck.Analysis.Events
  alias Soundcheck.Analysis.LiveModules
  alias Soundcheck.Analysis.MountHooks
  alias Soundcheck.Graph

  @doc """
  Adds every link in `needs` that `graph` lacks. The links are independent
  of each other, so they compute in parallel.
  """
  @spec link(Graph.t(), [Graph.link()]) :: Graph.t()
  def link(%Graph{} = graph, needs) do
    needs
    |> Enum.uniq()
    |> Enum.filter(&(Map.fetch!(graph, &1) == :not_linked))
    |> Task.async_stream(&{&1, compute(&1, graph)}, timeout: :infinity)
    |> Enum.reduce(graph, fn {:ok, {link, value}}, graph -> Map.put(graph, link, value) end)
  end

  @doc "Computes `link` for `graph`."
  @spec compute(Graph.link(), Graph.t()) :: term()
  def compute(:live_modules, graph), do: LiveModules.all(graph)
  def compute(:routes, graph), do: MountHooks.routes(graph)
  def compute(:render_index, graph), do: Components.render_index(graph)
  def compute(:js_helpers, graph), do: Events.js_helpers(graph)
end
