defmodule Soundcheck.Analysis.AssignUse do
  @moduledoc false
  # Where a LiveView or LiveComponent writes and reads its own assigns, from
  # source.
  #
  # Writes are literal keys passed to `assign/2,3`, `assign_new/3`,
  # `update/3`, and `assign_async/3,4`. Reads are `@key` in the module's
  # templates and in every layout module's templates, plus `assigns.key`,
  # `socket.assigns.key`, `assigns[:key]`, `Map.get(socket.assigns, :key)`,
  # and `%{assigns: %{key: _}}` patterns in its functions, and in the
  # functions of other project modules it hands its socket to
  # (`socket |> LogHelpers.assign_tz(params)`, `Helpers.load(socket)`),
  # followed through their calls that pass on the piped value or a
  # variable named `socket`, a few calls deep. Spreading
  # `{assigns}` into a layout component (`<Layouts.app {assigns}>`) reads
  # only what the layout's templates read.
  #
  # Any other use of the assigns map, such as passing `socket.assigns` or
  # `{assigns}` along whole, could read any key: the reads are then `open`
  # and rules make no claim about unread keys.

  alias Soundcheck.Analysis.Components
  alias Soundcheck.Elixir.ModuleIndex
  alias Soundcheck.Elixir.ModuleIndex.Entry
  alias Soundcheck.Graph
  alias Soundcheck.Heex.Node
  alias Soundcheck.Heex.Reads
  alias Soundcheck.Heex.Walker

  defmodule Write do
    @moduledoc false
    # One literal-key write to the socket. `value` is the written
    # expression, `nil` for `assign_async/3`.
    @enforce_keys [:key, :call, :value, :line, :column]
    defstruct [:key, :call, :value, :line, :column]

    @type t :: %__MODULE__{
            key: atom(),
            call: :assign | :assign_new | :update | :assign_async,
            value: Macro.t() | nil,
            line: pos_integer(),
            column: pos_integer()
          }
  end

  defmodule ReadSet do
    @moduledoc false
    # The assign keys a module reads: in its functions (`code`) and in the
    # templates it renders (`template`). `open?` is `true` when the
    # analysis cannot list every read.
    @enforce_keys [:code, :template, :open?]
    defstruct [:code, :template, :open?]

    @type t :: %__MODULE__{code: MapSet.t(atom()), template: [atom()], open?: boolean()}
  end

  @type write :: Write.t()
  @type reads :: ReadSet.t()
  @type layout_reads :: {[atom()], boolean()}

  @writers [:assign, :assign_new, :update, :assign_async]
  @map_readers [:get, :fetch, :fetch!, :has_key?]

  # How many calls deep `helper_reads/2` follows the socket.
  @helper_depth 4

  @doc """
  Every literal-key write to the socket in `entry`'s functions, in source
  order. Function components defined in the module write their own
  assigns, so their writes are left out.
  """
  @spec writes(Entry.t()) :: [write()]
  def writes(%Entry{functions: functions}) do
    writes =
      for {{name, arity}, clauses} <- functions,
          clause <- clauses,
          not component?(name, arity, clause),
          write <- body_writes(clause.body),
          do: write

    Enum.sort_by(writes, &{&1.line, &1.column})
  end

  @doc """
  The keys the layout modules' templates read (one entry per read), and
  whether some use of the assigns map there could read any key. Every
  module shares them, so rules compute them once per graph and pass them
  to `reads/3`.
  """
  @spec layout_reads(Graph.t()) :: layout_reads()
  def layout_reads(%Graph{} = graph) do
    for(%Entry{name: name} <- graph.modules, layout?(name), uniq: true, do: name)
    |> Enum.flat_map(&Graph.templates_of(graph, &1))
    |> template_reads()
  end

  @doc """
  The keys `entry` reads in code, the keys its templates and the layouts
  read (one entry per read), and whether some use of the assigns map could
  read any key. `layout_reads` comes from `layout_reads/1`.
  """
  @spec reads(Graph.t(), Entry.t(), layout_reads()) :: reads()
  def reads(%Graph{} = graph, %Entry{} = entry, {layout_keys, layout_open?}) do
    {code, code_open?} = code_reads(entry)
    {template_keys, template_open?} = template_reads(templates(graph, entry))

    %ReadSet{
      code: MapSet.union(code, helper_reads(graph, entry)),
      template: template_keys ++ layout_keys,
      open?: code_open? or template_open? or layout_open?
    }
  end

  @doc "The keys `entry`'s templates iterate directly with `:for={x <- @key}`."
  @spec for_sources(Graph.t(), Entry.t()) :: MapSet.t(atom())
  def for_sources(%Graph{} = graph, %Entry{} = entry) do
    for template <- templates(graph, entry),
        %Node.Element{attrs: attrs} <- Walker.elements(template.root),
        %Node.Attr{name: ":for", value: {:expr, {:<-, _, [_pattern, source]}, _, _}} <- attrs,
        {:@, _, [{key, _, context}]} <- [source],
        is_atom(key) and is_atom(context),
        into: MapSet.new(),
        do: key
  end

  @doc "The keys `mount/3` returns as `temporary_assigns`."
  @spec temporary(Entry.t()) :: MapSet.t(atom())
  def temporary(%Entry{functions: functions}) do
    for clause <- Map.get(functions, {:mount, 3}, []),
        {:ok, _socket, opts} <- returns(clause.body),
        Keyword.keyword?(opts),
        temporary = Keyword.get(opts, :temporary_assigns, []),
        Keyword.keyword?(temporary),
        {key, _default} <- temporary,
        into: MapSet.new(),
        do: key
  end

  defp returns({:__block__, _, statements}), do: statements |> List.last() |> List.wrap()
  defp returns({:{}, _, [:ok, socket, opts]}), do: [{:ok, socket, opts}]
  defp returns(_body), do: []

  # The module's own templates and those its render/1 delegates to.
  defp templates(graph, %Entry{name: name}),
    do: Enum.uniq(Graph.templates_of(graph, name) ++ Components.render_templates(graph, name))

  defp layout?(name) when is_atom(name) and not is_nil(name), do: inspect(name) =~ ~r/Layouts?$/

  defp layout?(_name), do: false

  # ── Writes ──

  defp body_writes(body) do
    {_ast, writes} =
      Macro.prewalk(body, [], fn
        {:fn, _, _clauses} = node, acc ->
          {node, acc}

        # The pipe supplies the socket; walking on into `[socket | args]`
        # keeps the call itself from being read again without it.
        {:|>, _, [socket, {name, meta, args}]}, acc when name in @writers and is_list(args) ->
          {[socket | args], Enum.reverse(write_keys(name, [socket | args], meta), acc)}

        {name, meta, args} = node, acc when name in @writers and is_list(args) ->
          {node, Enum.reverse(write_keys(name, args, meta), acc)}

        {{:., _, [module, name]}, meta, args} = node, acc when name in @writers ->
          if assigns_module?(module),
            do: {node, Enum.reverse(write_keys(name, args, meta), acc)},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(writes)
  end

  # `Phoenix.Component.assign/3` and `Phoenix.LiveView.update/3` write
  # assigns; `Keyword.update/4` and `Map.update/4` do not.
  defp assigns_module?({:__aliases__, _, parts}),
    do: parts in [[:Phoenix, :Component], [:Phoenix, :LiveView], [:Component], [:LiveView]]

  defp assigns_module?(module), do: module in [Phoenix.Component, Phoenix.LiveView]

  # `args` starts with the socket. `assign(assigns, ...)` writes a
  # component's assigns, not the socket's.
  defp write_keys(_call, [{:assigns, _, context} | _args], _meta) when is_atom(context), do: []

  defp write_keys(call, [_socket, key, value | _], meta) when is_atom(key),
    do: [write(call, key, value, meta)]

  defp write_keys(:assign_async, [_socket, keys | _], meta) when is_list(keys),
    do: for(key <- keys, is_atom(key), do: write(:assign_async, key, nil, meta))

  defp write_keys(call, [_socket, [{key, _} | _] = keyword], meta) when is_atom(key),
    do: for({key, value} <- keyword, do: write(call, key, value, meta))

  defp write_keys(_call, _args, _meta), do: []

  defp write(call, key, value, meta),
    do: %Write{key: key, call: call, value: value, line: meta[:line], column: meta[:column]}

  # ── Reads ──

  defp code_reads(%Entry{functions: functions}) do
    for {{name, arity}, clauses} <- functions,
        clause <- clauses,
        not component?(name, arity, clause),
        reduce: {MapSet.new(), false} do
      {keys, open?} ->
        {head_keys, _open?} = walk(clause.args, true)
        {body_keys, body_open?} = walk(clause.body, false)
        {keys |> MapSet.union(head_keys) |> MapSet.union(body_keys), open? or body_open?}
    end
  end

  # Reads in other project modules' functions that receive the socket. A
  # helper's own calls into its module or others follow the same rule.
  defp helper_reads(graph, entry) do
    modules = Map.new(graph.modules, &{&1.name, &1})

    calls =
      for {_name_arity, clauses} <- entry.functions,
          clause <- clauses,
          {module, _fun, _arity} = call <- socket_calls(clause.body, entry, modules),
          module != entry.name,
          do: call

    follow_helpers(calls, modules, %{}, @helper_depth, MapSet.new())
  end

  defp follow_helpers([], _modules, _seen, _depth, keys), do: keys
  defp follow_helpers(_calls, _modules, _seen, 0, keys), do: keys

  defp follow_helpers(calls, modules, seen, depth, keys) do
    fresh = calls |> Enum.uniq() |> Enum.reject(&Map.has_key?(seen, &1))
    seen = Enum.reduce(fresh, seen, &Map.put(&2, &1, true))

    {keys, next} =
      Enum.reduce(fresh, {keys, []}, fn {module, fun, arity}, {keys, next} ->
        helper = Map.fetch!(modules, module)
        clauses = Map.get(helper.functions, {fun, arity}, [])
        keys = Enum.reduce(clauses, keys, &MapSet.union(&2, clause_keys(&1)))
        {keys, [Enum.flat_map(clauses, &socket_calls(&1.body, helper, modules)) | next]}
      end)

    follow_helpers(Enum.concat(next), modules, seen, depth - 1, keys)
  end

  defp clause_keys(clause) do
    {head_keys, _open?} = walk(clause.args, true)
    {body_keys, _open?} = walk(clause.body, false)
    MapSet.union(head_keys, body_keys)
  end

  # `{module, fun, arity}` of each project function `body` hands a socket:
  # the right side of a pipe, or a call with a `socket` variable argument.
  defp socket_calls(body, entry, modules) do
    for node <- Macro.prewalker(body),
        {call, arity} <- socket_call(node),
        target = resolve_call(call, arity, entry, modules),
        target != nil,
        do: target
  end

  defp socket_call({:|>, _, [_value, {_name, _meta, args} = call]}) when is_list(args),
    do: [{call, length(args) + 1}]

  defp socket_call({_name, _meta, args} = call) when is_list(args) do
    if Enum.any?(args, &socket_var?/1), do: [{call, length(args)}], else: []
  end

  defp socket_call(_node), do: []

  defp socket_var?({:socket, _meta, context}) when is_atom(context), do: true
  defp socket_var?(_node), do: false

  defp resolve_call({{:., _, [alias, fun]}, _meta, _args}, arity, entry, modules)
       when is_atom(fun) do
    with module when is_atom(module) <- ModuleIndex.expand(alias, entry.aliases),
         %Entry{functions: functions} <- Map.get(modules, module),
         true <- Map.has_key?(functions, {fun, arity}) do
      {module, fun, arity}
    else
      _unresolved -> nil
    end
  end

  defp resolve_call({fun, _meta, _args}, arity, entry, _modules) when is_atom(fun) do
    if Map.has_key?(entry.functions, {fun, arity}), do: {entry.name, fun, arity}
  end

  defp resolve_call(_call, _arity, _entry, _modules), do: nil

  # Function components defined in the module read their own assigns.
  defp component?(:render, 1, _clause), do: false
  defp component?(_name, 1, %{args: [{:assigns, _, context}]}) when is_atom(context), do: true
  defp component?(_name, _arity, _clause), do: false

  # `@key` reads, plus reads through the assigns map (`assigns[:key]`,
  # `Map.get(assigns, :key)`) that `walk/2` finds.
  defp template_reads(templates) do
    keys = for template <- templates, read <- Reads.assigns(template), do: read.key

    {walked, open?} =
      Enum.map_reduce(templates, false, fn template, open? ->
        {walked, walked_open?} =
          template |> Reads.expressions() |> Kernel.--(layout_spreads(template)) |> walk(false)

        {walked, open? or walked_open?}
      end)

    {keys ++ Enum.concat(walked), open?}
  end

  # `<Layouts.app {assigns}>` hands every assign to a layout component, whose
  # template reads count already.
  defp layout_spreads(template) do
    for %Node.Element{tag: tag, attrs: attrs} <- Walker.elements(template.root),
        tag =~ ~r/(^|\.)Layouts?\.\w+$/,
        %Node.Attr{name: :root, value: {:expr, ast, _source, _span}} <- attrs,
        do: ast
  end

  # Walks `ast` for assigns-map reads. In a function head (`head?`), only
  # `%{assigns: %{key: _}}` patterns count and a bare `assigns` variable is
  # the binding, not a use. A matched read drops its subtree, so the
  # `assigns` inside `assigns.key` does not count again as an open read.
  defp walk(ast, head?) do
    {_ast, acc} =
      Macro.prewalk(ast, {MapSet.new(), false}, fn node, {keys, open?} ->
        case read(node) do
          {:keys, read_keys} -> {nil, {Enum.into(read_keys, keys), open?}}
          :open when not head? -> {nil, {keys, true}}
          _other -> {node, {keys, open?}}
        end
      end)

    acc
  end

  defp read({:assigns, {:%{}, _, pairs}}), do: {:keys, map_keys(pairs)}

  defp read(node) do
    case access(node) do
      {base, keys} -> if assigns?(base), do: {:keys, keys}, else: open(node)
      nil -> open(node)
    end
  end

  defp open(node), do: if(assigns?(node), do: :open)

  # `{base, keys}` for an expression that reads `keys` from `base`.
  defp access({{:., _, [base, key]}, _, []}) when is_atom(key), do: {base, [key]}

  defp access({{:., _, [Access, :get]}, _, [base, key | _]}) when is_atom(key), do: {base, [key]}

  defp access({{:., _, [{:__aliases__, _, [:Map]}, fun]}, _, [base, key | _]})
       when fun in @map_readers and is_atom(key), do: {base, [key]}

  defp access({:=, _, [{:%{}, _, pairs}, base]}), do: {base, map_keys(pairs)}
  defp access(_node), do: nil

  defp map_keys(pairs), do: for({key, _value} <- pairs, is_atom(key), do: key)

  defp assigns?({:assigns, _, context}) when is_atom(context), do: true
  defp assigns?({{:., _, [_socket, :assigns]}, _, []}), do: true
  defp assigns?(_node), do: false
end
