defmodule Soundcheck.Heex.Walker do
  @moduledoc false
  # Traversals over parsed template trees.

  alias Soundcheck.Heex.Node

  @doc "Every element in `nodes`, depth first, including EEx block clauses."
  @spec elements([Node.t()] | Node.t()) :: [Node.Element.t()]
  def elements(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &elements/1)
  def elements(%Node.Element{children: children} = element), do: [element | elements(children)]

  def elements(%Node.EexBlock{clauses: clauses}),
    do: Enum.flat_map(clauses, &elements(&1.children))

  def elements(_node), do: []
end
