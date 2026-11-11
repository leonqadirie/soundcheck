defmodule Soundcheck.HeexCase do
  @moduledoc false
  # Helpers for HEEx parser tests: collecting nodes from a tree and reading
  # the source text a span covers, so position tests can assert "this span
  # covers exactly this text" instead of hard-coding coordinates.

  alias Soundcheck.Heex.Node
  alias Soundcheck.Span

  defmacro __using__(_opts) do
    quote do
      use ExUnit.Case, async: true

      import Soundcheck.HeexCase

      alias Soundcheck.Heex.Node
      alias Soundcheck.Heex.Parser
    end
  end

  @doc "Returns the source text covered by `span`, which must lie in `source`."
  def text_at(source, %Span{start: {line, col}, stop: {stop_line, stop_col}}) do
    lines = String.split(source, "\n")

    if line == stop_line do
      lines |> Enum.at(line - 1) |> String.slice((col - 1)..(stop_col - 2)//1)
    else
      first = lines |> Enum.at(line - 1) |> String.slice((col - 1)..-1//1)
      middle = Enum.slice(lines, line..(stop_line - 2)//1)
      last = lines |> Enum.at(stop_line - 1) |> String.slice(0..(stop_col - 2)//1)
      Enum.join([first | middle] ++ [last], "\n")
    end
  end

  @doc "Every node in the tree, depth first, including slot and block children."
  def nodes(tree) when is_list(tree), do: Enum.flat_map(tree, &nodes/1)

  def nodes(%Node.Element{children: children} = element), do: [element | nodes(children)]

  def nodes(%Node.EexBlock{clauses: clauses} = block),
    do: [block | Enum.flat_map(clauses, &nodes(&1.children))]

  def nodes(node), do: [node]

  @doc "Every element in the tree, depth first."
  def elements(tree), do: for(%Node.Element{} = element <- nodes(tree), do: element)

  @doc "The first element with the given tag."
  def element(tree, tag), do: Enum.find(elements(tree), &(&1.tag == tag))

  @doc "The attribute with the given name on `element`."
  def attr(%Node.Element{attrs: attrs}, name), do: Enum.find(attrs, &(&1.name == name))
end
