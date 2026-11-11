defmodule Soundcheck.Elixir.Names do
  @moduledoc false
  # Module names as written in source.

  @doc """
  Returns the module a `defmodule` name AST defines inside `parent` (`nil`
  at the top level): a nested `defmodule Child` inside `Parent` defines
  `Parent.Child`. A leading `__MODULE__` stands for `parent`, so
  `defmodule __MODULE__.Child` defines `Parent.Child` too, and `Child` at
  the top level, where `__MODULE__` is `nil`. Names built from other
  expressions (`defmodule unquote(name)`) have no literal module and return
  `nil`.
  """
  @spec module_name(Macro.t(), module() | nil) :: module() | nil
  def module_name({:__aliases__, meta, [{:__MODULE__, _, context} | segments]}, parent)
      when is_atom(context), do: module_name({:__aliases__, meta, segments}, parent)

  def module_name({:__aliases__, _meta, segments}, parent) do
    cond do
      not Enum.all?(segments, &is_atom/1) -> nil
      parent -> Module.concat([parent | segments])
      true -> Module.concat(segments)
    end
  end

  def module_name(_name, _parent), do: nil
end
