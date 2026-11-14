defmodule Soundcheck.Analysis.Connected do
  @moduledoc false
  # What a branch condition evaluates to in one run of `mount/3`: the
  # disconnected (HTTP) run or the connected (websocket) run.
  #
  # `connected?(socket)` is the only operand with a known value. Negations
  # (`not`, `!`) flip it, and the short-circuit connectives (`and`, `&&`,
  # `or`, `||`) combine it with operands of unknown value: `connected?(socket)
  # and flag?` is false when disconnected and unknown when connected.

  @typedoc "The value of a condition in one run; `:either` when the run does not fix it."
  @type outcome :: boolean() | :either

  @negations [:not, :!]
  @conjunctions [:and, :&&]
  @disjunctions [:or, :||]

  @doc "The value `condition` takes in the run that `connected?` selects."
  @spec outcome(Macro.t(), boolean()) :: outcome()
  def outcome({:connected?, _, [_socket]}, connected?), do: connected?
  def outcome({{:., _, [_module, :connected?]}, _, [_socket]}, connected?), do: connected?

  def outcome({negation, _, [condition]}, connected?) when negation in @negations do
    case outcome(condition, connected?) do
      :either -> :either
      value -> not value
    end
  end

  def outcome({op, _, [left, right]}, connected?) when op in @conjunctions,
    do: combine(outcome(left, connected?), outcome(right, connected?), false)

  def outcome({op, _, [left, right]}, connected?) when op in @disjunctions,
    do: combine(outcome(left, connected?), outcome(right, connected?), true)

  def outcome(_condition, _connected?), do: :either

  # `decisive` is the operand value that fixes the connective's result:
  # `false` for a conjunction, `true` for a disjunction.
  defp combine(decisive, _right, decisive), do: decisive
  defp combine(_left, decisive, decisive), do: decisive
  defp combine(:either, _right, _decisive), do: :either
  defp combine(_left, right, _decisive), do: right

  @doc """
  The operands of `condition` that the selected run can evaluate, in source
  order. A connective skips its right operand when the left one decides it:
  the disconnected run never evaluates `flag?()` in
  `connected?(socket) and flag?()`.
  """
  @spec reachable(Macro.t(), boolean()) :: [Macro.t()]
  def reachable({negation, _, [condition]}, connected?) when negation in @negations,
    do: reachable(condition, connected?)

  def reachable({op, _, [left, right]}, connected?) when op in @conjunctions,
    do: reachable(left, right, connected?, false)

  def reachable({op, _, [left, right]}, connected?) when op in @disjunctions,
    do: reachable(left, right, connected?, true)

  def reachable(operand, _connected?), do: [operand]

  defp reachable(left, right, connected?, decisive) do
    if outcome(left, connected?) == decisive,
      do: reachable(left, connected?),
      else: reachable(left, connected?) ++ reachable(right, connected?)
  end
end
