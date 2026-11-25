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
  #
  # A link has two forms. `compute/2` returns the stored form, which leaves
  # the computing task as a message (`link/2`) or enters a persistent term
  # (`Soundcheck.Graph.Current`). Both copy every graph term the value
  # holds, once per reference, so the stored form names templates and
  # modules by id. `resolve/2` runs in the process that reads the link and
  # swaps the ids for the graph's own terms, which costs no copy. Checks
  # read the resolved form. `Soundcheck.Graph.StoredLink` wraps the stored
  # form, so neither passes for the other.

  alias Soundcheck.Analysis.Components
  alias Soundcheck.Analysis.Events
  alias Soundcheck.Analysis.LiveHosts
  alias Soundcheck.Analysis.LiveModules
  alias Soundcheck.Analysis.MountHooks
  alias Soundcheck.Graph
  alias Soundcheck.Graph.StoredLink

  @doc """
  Adds every link in `needs` that `graph` lacks. The links are independent
  of each other, so they compute in parallel.
  """
  @spec link(Graph.t(), [Graph.link()]) :: Graph.t()
  def link(%Graph{} = graph, needs) do
    needs
    |> Enum.uniq()
    |> Enum.filter(&(Map.fetch!(graph, &1) == :not_linked))
    |> Task.async_stream(&compute(&1, graph), timeout: :infinity)
    |> Enum.reduce(graph, fn {:ok, %StoredLink{link: link} = stored}, acc ->
      Map.put(acc, link, resolve(stored, graph))
    end)
  end

  @doc """
  Computes the stored form of `link` for `graph`. The result holds no
  template, module entry, or other term of `graph`.
  """
  @spec compute(Graph.link(), Graph.t()) :: StoredLink.t()
  def compute(link, %Graph{} = graph), do: %StoredLink{link: link, value: stored(link, graph)}

  defp stored(:live_modules, graph), do: LiveModules.all(graph)
  defp stored(:routes, graph), do: MountHooks.routes(graph)
  defp stored(:render_index, graph), do: Components.render_index(graph)
  defp stored(:js_helpers, graph), do: Events.js_helpers(graph)
  defp stored(:live_hosts, graph), do: LiveHosts.infer(graph)

  @doc """
  Turns a stored link into the value checks read, given the graph
  `compute/2` read.
  """
  @spec resolve(StoredLink.t(), Graph.t()) :: term()
  def resolve(%StoredLink{link: link, value: value}, %Graph{} = graph),
    do: resolved(link, value, graph)

  defp resolved(:render_index, index, graph), do: Components.resolve_index(index, graph)
  defp resolved(:live_modules, entries, _graph), do: entries
  defp resolved(:routes, routes, _graph), do: routes
  defp resolved(:js_helpers, helpers, _graph), do: helpers
  defp resolved(:live_hosts, hosts, _graph), do: hosts
end
