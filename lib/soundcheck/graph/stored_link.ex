defmodule Soundcheck.Graph.StoredLink do
  @moduledoc false
  # A link as `Soundcheck.Graph.Link.compute/2` returns it: `value` names
  # templates and modules by name or position and holds no term of the
  # graph, so a persistent term or a task message copies it cheaply.
  #
  # The struct keeps a stored link apart from the value checks read.
  # `Soundcheck.Graph.Link.resolve/2` accepts nothing else, and a graph's
  # link accessors raise on one.

  @enforce_keys [:link, :value]
  defstruct [:link, :value]

  @type t :: %__MODULE__{link: Soundcheck.Graph.link(), value: term()}
end
