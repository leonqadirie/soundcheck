defmodule Soundcheck.Analysis.Handlers do
  @moduledoc false
  # Reads LiveView callback handlers and message emitters from compiled
  # modules' expanded ASTs.
  #
  # A handler set is `closed?` when soundcheck can list every message the
  # module accepts: the module carries debug info, and no `attach_hook/4` in
  # the module or in its `on_mount` hooks, declared in the module or by the
  # `live_session` of a route to it, targets the callback's stage. Rules
  # report an unhandled message only against a closed set.
  #
  # Each public function memoizes its AST walks per module per run through
  # `Soundcheck.Once`: rules ask once per emitter, and every fresh answer
  # walks the module's whole expanded AST.
  #
  # Expansion shapes these functions read (verified on LiveView 1.2 and
  # Elixir 1.18 through 1.20):
  #
  #   * `"prefix" <> rest` in a head is `<<"prefix", rest::binary>>`;
  #   * `when event in ["a", "b"]` is an `:erlang.orelse` chain of
  #     `:erlang."=:="(event, "a")`;
  #   * `start_async/3` is `Phoenix.LiveView.Async.start_async/4`;
  #   * `send/2` and `Process.send/3` are `:erlang.send/2,3`, and `self()` is
  #     `:erlang.self()`;
  #   * `Process.send_after/3` stays as written on Elixir 1.20 and is
  #     `:erlang.send_after(time, pid, message)` on Elixir 1.19 and earlier.

  alias Soundcheck.Analysis.MountHooks
  alias Soundcheck.Beam.DebugInfo
  alias Soundcheck.Beam.Introspect
  alias Soundcheck.Once

  @type pattern ::
          {:literal, String.t()}
          | {:prefix, String.t()}
          | {:atom, atom()}
          | {:tagged, atom(), pos_integer()}
          | {:tuple, pos_integer()}
          | :any
          | :other

  @type message :: {:atom, atom()} | {:tagged, atom(), pos_integer()}

  defmodule HandlerSet do
    @moduledoc false
    # The messages one callback stage of a module accepts. `open_reasons`
    # lists why the set may be incomplete (`:attach_hook`,
    # `:hook_module_unreadable`); the set is `closed?` when it lists none.
    @enforce_keys [:patterns, :closed?, :open_reasons]
    defstruct [:patterns, :closed?, :open_reasons]

    @type t :: %__MODULE__{
            patterns: [Soundcheck.Analysis.Handlers.pattern()],
            closed?: boolean(),
            open_reasons: [Soundcheck.Diagnostic.reason()]
          }

    @spec new([Soundcheck.Analysis.Handlers.pattern()], [Soundcheck.Diagnostic.reason()]) :: t()
    def new(patterns, open_reasons),
      do: %__MODULE__{patterns: patterns, closed?: open_reasons == [], open_reasons: open_reasons}

    @doc """
    The resolution of a finding that `set` leaves unhandled: resolved when
    the set is closed, unverifiable for its first open reason otherwise.
    """
    @spec resolution(t()) :: Soundcheck.Diagnostic.resolution()
    def resolution(%__MODULE__{open_reasons: []}), do: :resolved
    def resolution(%__MODULE__{open_reasons: [reason | _]}), do: {:unverifiable, reason}
  end

  defmodule Sender do
    @moduledoc false
    # A call that delivers a message to a callback: `start_async` to
    # `handle_async/3`, `send` to `handle_info/2`. Macro-expanded calls
    # (`start_async`) carry no column; `Soundcheck.Analysis.LiveModules.span/2`
    # recovers it from source.
    @enforce_keys [:message, :line, :call]
    defstruct [:message, :line, :column, :call]

    @type t :: %__MODULE__{
            message: Soundcheck.Analysis.Handlers.message(),
            line: pos_integer(),
            column: pos_integer() | nil,
            call: String.t()
          }
  end

  @type handler_set :: HandlerSet.t()

  @stages %{handle_event: 3, handle_info: 2, handle_async: 3}

  @doc """
  Returns the handler set for `stage` (`:handle_event`, `:handle_info`, or
  `:handle_async`) of `module`, or `{:error, reason}` when the module cannot
  be read. `routes` are the project's live routes (`MountHooks.routes/1`),
  whose `live_session` hooks may attach handlers.

  The clause patterns and each module's `attach_hook` scan are memoized per
  module and stage; which hook modules apply depends on `routes`, so each
  call works that out afresh.
  """
  @spec handler_set(module(), atom(), [Introspect.route()]) ::
          {:ok, handler_set()} | {:error, DebugInfo.error()}
  def handler_set(module, stage, routes) when is_map_key(@stages, stage) do
    with {:ok, patterns} <- patterns(module, stage) do
      {:ok, HandlerSet.new(patterns, attach_hook_reasons(module, stage, routes))}
    end
  end

  defp patterns(module, stage) do
    Once.run({__MODULE__, :patterns, module, stage}, fn ->
      with {:ok, clauses} <- DebugInfo.clauses(module, stage, Map.fetch!(@stages, stage)),
           do: {:ok, Enum.flat_map(clauses, &clause_patterns(&1, stage))}
    end)
  end

  @doc """
  The `{key, value}` pairs a map pattern requires, including both sides of
  a `=` binding. Any other pattern requires none.
  """
  @spec map_pattern_pairs(Macro.t()) :: [{Macro.t(), Macro.t()}]
  def map_pattern_pairs({:%{}, _, pairs}), do: pairs

  def map_pattern_pairs({:=, _, [left, right]}),
    do: Enum.flat_map([left, right], &map_pattern_pairs/1)

  def map_pattern_pairs(_pattern), do: []

  @doc "Returns `true` when a pattern in `set` accepts `message`."
  @spec handles?(handler_set(), message() | {:literal, String.t()}) :: boolean()
  def handles?(%HandlerSet{patterns: patterns}, message),
    do: Enum.any?(patterns, &matches?(&1, message))

  @doc """
  Returns the `start_async/3` calls in `module` whose name is a literal atom
  or a tuple tagged with one.
  """
  @spec async_starts(module()) :: {:ok, [Sender.t()]} | {:error, DebugInfo.error()}
  def async_starts(module),
    do: Once.run({__MODULE__, :async_starts, module}, fn -> read_async_starts(module) end)

  defp read_async_starts(module) do
    collect_calls(module, fn
      {{:., _, [async, :start_async]}, meta, [_socket, name | _]}
      when async in [Phoenix.LiveView.Async, Phoenix.LiveView] ->
        emitter(message(name), meta, "start_async")

      _node ->
        nil
    end)
  end

  @doc """
  Returns the messages `module` sends to its own process with `send/2`,
  `Process.send/3`, or `Process.send_after/3,4`, when the message is a
  literal atom or a tuple tagged with one.
  """
  @spec self_sends(module()) :: {:ok, [Sender.t()]} | {:error, DebugInfo.error()}
  def self_sends(module),
    do: Once.run({__MODULE__, :self_sends, module}, fn -> read_self_sends(module) end)

  defp read_self_sends(module) do
    collect_calls(module, fn
      {{:., _, [:erlang, :send]}, meta, [self, message | _]} ->
        if self?(self), do: emitter(message(message), meta, "send")

      {{:., _, [Process, :send_after]}, meta, [self, message | _]} ->
        if self?(self), do: emitter(message(message), meta, "Process.send_after")

      # Elixir 1.19 and earlier inline `Process.send_after/3,4`.
      {{:., _, [:erlang, :send_after]}, meta, [_time, self, message | _]} ->
        if self?(self), do: emitter(message(message), meta, "Process.send_after")

      _node ->
        nil
    end)
  end

  # ── Handler patterns ──

  defp clause_patterns({_meta, [first | _], guards, _body}, :handle_event),
    do: event_patterns(first, guards)

  defp clause_patterns({_meta, [first | _], _guards, _body}, _stage), do: [term_pattern(first)]

  defp event_patterns(binary, _guards) when is_binary(binary), do: [{:literal, binary}]

  defp event_patterns({:<<>>, _, [{:"::", _, [prefix, _type]} | _rest]}, _guards)
       when is_binary(prefix), do: [{:prefix, prefix}]

  defp event_patterns({:=, _, [left, right]}, guards) do
    case {event_patterns(left, guards), event_patterns(right, guards)} do
      {[:any], specific} -> specific
      {specific, _right} -> specific
    end
  end

  defp event_patterns({name, _, context} = var, guards) when is_atom(name) and is_atom(context) do
    case guard_literals(guards, var) do
      {:ok, literals} -> Enum.map(literals, &{:literal, &1})
      :error -> [:any]
    end
  end

  defp event_patterns(_pattern, _guards), do: [:any]

  # A guard that is a chain of `var =:= "literal"` alternatives restricts the
  # event to those literals; any other guard leaves the clause open.
  defp guard_literals([guard], var), do: or_literals(guard, var)
  defp guard_literals(_guards, _var), do: :error

  defp or_literals({{:., _, [:erlang, :orelse]}, _, [left, right]}, var) do
    with {:ok, left} <- or_literals(left, var),
         {:ok, right} <- or_literals(right, var),
         do: {:ok, left ++ right}
  end

  defp or_literals({{:., _, [:erlang, :"=:="]}, _, [{name, _, _}, literal]}, {name, _, _})
       when is_binary(literal), do: {:ok, [literal]}

  defp or_literals(_guard, _var), do: :error

  defp term_pattern(atom) when is_atom(atom), do: {:atom, atom}
  defp term_pattern({tag, _second}) when is_atom(tag), do: {:tagged, tag, 2}
  defp term_pattern({_first, _second}), do: {:tuple, 2}

  defp term_pattern({:{}, _, [tag | _] = elements}) when is_atom(tag),
    do: {:tagged, tag, length(elements)}

  defp term_pattern({:{}, _, elements}) when is_list(elements), do: {:tuple, length(elements)}

  defp term_pattern({:=, _, [left, right]}) do
    case {term_pattern(left), term_pattern(right)} do
      {:any, specific} -> specific
      {specific, _right} -> specific
    end
  end

  defp term_pattern({name, _, context}) when is_atom(name) and is_atom(context), do: :any
  defp term_pattern(_pattern), do: :other

  defp matches?(:any, _message), do: true
  defp matches?(pattern, pattern), do: true
  defp matches?({:prefix, prefix}, {:literal, event}), do: String.starts_with?(event, prefix)
  defp matches?({:tuple, size}, {:tagged, _tag, size}), do: true
  defp matches?(_pattern, _message), do: false

  # ── attach_hook ──
  #
  # `attach_hook(socket, name, stage, fun)` in the module or in any of its
  # `on_mount` hook modules adds handlers soundcheck does not read.

  defp attach_hook_reasons(module, stage, routes) do
    [module | MountHooks.hook_modules(module, routes)]
    |> Enum.uniq()
    |> Enum.flat_map(&attaches?(&1, stage))
    |> Enum.uniq()
  end

  defp attaches?(module, stage),
    do: Once.run({__MODULE__, :attaches, module, stage}, fn -> read_attaches(module, stage) end)

  defp read_attaches(module, stage) do
    case DebugInfo.definitions(module) do
      {:ok, %DebugInfo.Info{definitions: definitions}} ->
        if Enum.any?(definitions, &attaches_in?(&1, stage)), do: [:attach_hook], else: []

      {:error, _reason} ->
        [:hook_module_unreadable]
    end
  end

  defp attaches_in?({_name_arity, _kind, _meta, clauses}, stage) do
    Enum.any?(clauses, fn {_meta, _args, _guards, body} ->
      body
      |> Macro.prewalker()
      |> Enum.any?(fn
        {{:., _, [Phoenix.LiveView, :attach_hook]}, _, [_socket, _name, hook_stage, _fun]} ->
          hook_stage == stage or not is_atom(hook_stage)

        _node ->
          false
      end)
    end)
  end

  # ── Senders ──

  defp collect_calls(module, fun) do
    with {:ok, %DebugInfo.Info{definitions: definitions}} <- DebugInfo.definitions(module) do
      emitters =
        for {_name_arity, _kind, _meta, clauses} <- definitions,
            {_meta, _args, _guards, body} <- clauses,
            emitter <- calls_in(body, fun),
            do: emitter

      {:ok, emitters |> Enum.uniq() |> Enum.sort_by(&{&1.line, &1.column})}
    end
  end

  defp calls_in(body, fun) do
    for node <- Macro.prewalker(body), emitter = fun.(node), do: emitter
  end

  # Only calls written in the module's own file carry no `:file` metadata;
  # code injected by another module's macro may point elsewhere.
  defp emitter(nil, _meta, _call), do: nil

  defp emitter(message, meta, call) do
    if meta[:line] && !meta[:file],
      do: %Sender{message: message, line: meta[:line], column: meta[:column], call: call}
  end

  defp message(atom) when is_atom(atom) and not is_nil(atom) and not is_boolean(atom),
    do: {:atom, atom}

  defp message({tag, _second}) when is_atom(tag) and not is_nil(tag), do: {:tagged, tag, 2}

  defp message({:{}, _, [tag | _] = elements}) when is_atom(tag),
    do: {:tagged, tag, length(elements)}

  defp message(_dynamic), do: nil

  defp self?({{:., _, [:erlang, :self]}, _, []}), do: true
  defp self?(_target), do: false
end
