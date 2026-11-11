defmodule Soundcheck.Analysis.ComponentAssigns do
  @moduledoc false
  # Which keys a function component's body assigns before rendering.
  #
  # `assign/2,3`, `assign_new/3`, `update/3`, and `Map.put/3` with literal
  # keys add those keys. A source whose keys are unknown makes the result
  # `:open`: `assign(assigns, some_map)`, `Map.merge/2`, or rebinding
  # `assigns` through any other function (`assigns = normalize(assigns)`),
  # which could add any key.
  #
  # A clause whose head matches a key (`def button(%{href: _} = assigns)`)
  # runs only for callers that pass it: `head_keys/2` lists those keys for
  # the clause that holds a template.

  alias Soundcheck.Analysis.Assigns
  alias Soundcheck.Heex.Template

  @assign_calls [:assign, :assign_new, :update]

  @doc "The keys the clauses assign, or `:open`."
  @spec keys([map()]) :: {:ok, MapSet.t(atom())} | :open
  def keys(clauses) do
    Enum.reduce_while(clauses, {:ok, MapSet.new()}, fn clause, {:ok, keys} ->
      case body_keys(clause.body) do
        {:ok, body_keys} -> {:cont, {:ok, MapSet.union(keys, body_keys)}}
        :open -> {:halt, :open}
      end
    end)
  end

  @doc """
  The keys the head of the clause holding `template` matches in its map
  pattern: `href` for `def button(%{href: _} = assigns)`. The clause is the
  last one starting at or before an inline `~H` template; a template file
  belongs to no single clause and gets none.
  """
  @spec head_keys([map()], Template.t()) :: MapSet.t(atom())
  def head_keys(clauses, %Template{origin: :sigil, id: {_file, {line, _column}}}) do
    clauses
    |> Enum.filter(&(&1.line <= line))
    |> Enum.max_by(& &1.line, fn -> nil end)
    |> case do
      %{args: [pattern]} -> pattern_keys(pattern)
      _none -> MapSet.new()
    end
  end

  def head_keys(_clauses, %Template{}), do: MapSet.new()

  defp pattern_keys({:%{}, _, pairs}),
    do: for({key, _value} <- pairs, is_atom(key), into: MapSet.new(), do: key)

  defp pattern_keys({:=, _, [left, right]}),
    do: MapSet.union(pattern_keys(left), pattern_keys(right))

  defp pattern_keys(_pattern), do: MapSet.new()

  @doc """
  Returns `true` when `module` renders `fun` as a LiveView or LiveComponent
  `render/1`, whose assigns come from the socket rather than from attrs.
  """
  @spec live_render?(map(), atom()) :: boolean()
  def live_render?(%{kind: kind, functions: functions}, :render) do
    kind in [:live_view, :live_component] or
      Enum.any?(
        [{:mount, 1}, {:mount, 3}, {:update, 2}, {:handle_event, 3}],
        &Map.has_key?(functions, &1)
      )
  end

  def live_render?(_module, _fun), do: false

  defp body_keys(body) do
    body
    |> Macro.prewalker()
    |> Enum.reduce_while({:ok, MapSet.new()}, fn node, {:ok, keys} = acc ->
      case node_keys(node) do
        nil -> {:cont, acc}
        :open -> {:halt, :open}
        new_keys -> {:cont, {:ok, MapSet.union(keys, MapSet.new(new_keys))}}
      end
    end)
  end

  # `assigns = <expression>` rebinding through anything but assigning calls
  # can add any key.
  defp node_keys({:=, _, [{:assigns, _, context}, right]}) when is_atom(context),
    do: if(!assigning?(right), do: :open)

  defp node_keys({name, _meta, args}) when name in @assign_calls and is_list(args),
    do: literal_keys(args)

  defp node_keys({{:., _, [_module, name]}, _meta, args}) when name in @assign_calls,
    do: literal_keys(args)

  defp node_keys({{:., _, [{:__aliases__, _, [:Map]}, :merge]}, _meta, _args}), do: :open

  defp node_keys({{:., _, [{:__aliases__, _, [:Map]}, :put]}, _meta, args}),
    do: literal_keys(args)

  defp node_keys(_node), do: nil

  defp assigning?({:assigns, _, context}) when is_atom(context), do: true
  defp assigning?({:|>, _, [left, right]}), do: assigning?(left) and assigning?(right)
  defp assigning?({name, _, args}) when name in @assign_calls and is_list(args), do: true
  defp assigning?({{:., _, [_module, name]}, _, _args}) when name in @assign_calls, do: true
  defp assigning?({{:., _, [{:__aliases__, _, [:Map]}, :put]}, _, _args}), do: true
  defp assigning?(_expression), do: false

  # A map or variable argument could name any key.
  defp literal_keys(args) do
    case Assigns.literal_keys(args) do
      [] -> :open
      keys -> keys
    end
  end
end
