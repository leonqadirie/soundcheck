defmodule Soundcheck.Analysis.SocketNames do
  @moduledoc false
  # Names a LiveView or LiveComponent registers on its socket under one
  # assign, such as streams under `@streams` or uploads under `@uploads`,
  # and the places that use a name the module never registers.
  #
  # Definitions and uses are calls whose name argument is a literal atom:
  # the first argument of a piped call, else the second. Uses come from the
  # module's own functions. Definitions also come from the project functions
  # the module calls, followed through remote calls and imports to any depth.
  # Reads are `@assign.name` and `@assign[:name]` in the module's `render/1`
  # template, colocated or inline.

  alias Soundcheck.Analysis.Anchors
  alias Soundcheck.Analysis.Calls
  alias Soundcheck.Analysis.Components
  alias Soundcheck.Analysis.Suggest
  alias Soundcheck.Elixir.ModuleIndex
  alias Soundcheck.Elixir.ModuleIndex.Entry
  alias Soundcheck.Graph
  alias Soundcheck.Heex.Reads
  alias Soundcheck.Heex.Template
  alias Soundcheck.Span

  @type spec :: %{assign: atom(), defining: [atom()], using: [atom()]}
  defmodule Undefined do
    @moduledoc false
    # A use of a name the module does not define. `defined` lists the names it
    # does define, sorted; `anchor` is where Credo reports the use.
    @enforce_keys [:entry, :name, :defined, :span, :anchor]
    defstruct [:entry, :name, :defined, :span, :anchor]

    @type t :: %__MODULE__{
            entry: Entry.t(),
            name: atom(),
            defined: [atom()],
            span: Span.t(),
            anchor: Span.t()
          }
  end

  @type undefined :: Undefined.t()

  @doc """
  Every use of a name the module does not define, sorted by position.

  The module's definitions include those in the project functions it
  calls. The module is skipped when it and its helpers define no name,
  when any of them names one dynamically, or when it hands its socket to a
  function outside the project and Phoenix, which may define names the
  analysis cannot see.
  """
  @spec undefined(Graph.t(), spec()) :: [undefined()]
  def undefined(%Graph{} = graph, spec) do
    for %Entry{kind: kind} = entry <- graph.modules,
        kind in [:live_view, :live_component],
        calls = calls(entry, spec.defining ++ spec.using),
        {:ok, defined} <- [defined(graph, entry, calls, spec.defining)],
        {name, span, anchor} <- uses(graph, entry, calls, spec),
        name not in defined do
      %Undefined{
        entry: entry,
        name: name,
        defined: Enum.sort(defined),
        span: span,
        anchor: anchor
      }
    end
    |> Enum.sort_by(&{&1.span.file, &1.span.start})
  end

  @doc "A \"Did you mean\" hint naming the defined name closest to `name`, or `nil`."
  @spec suggestion(atom(), [atom()]) :: String.t() | nil
  def suggestion(name, defined) do
    case Suggest.closest(Atom.to_string(name), Enum.map(defined, &Atom.to_string/1)) do
      nil -> nil
      closest -> "Did you mean :#{closest}?"
    end
  end

  defp defined(graph, entry, calls, defining) do
    own = for {function, name, _meta} <- calls, function in defining, do: name
    visited = MapSet.new(Map.keys(entry.functions), &{entry.name, &1})

    with {:ok, names, _visited} <-
           follow(graph, entry, ModuleIndex.clauses(entry), defining, {own, visited}) do
      cond do
        names == [] -> :error
        Enum.all?(names, &is_atom/1) -> {:ok, Enum.uniq(names)}
        true -> :error
      end
    end
  end

  # ── Helper definitions ──
  #
  # `follow/5` walks the calls in `clauses` of `entry` into the project
  # functions they reach and collects each function's definitions once.
  # `visited` holds `{module, {fun, arity}}`, so cycles between helpers
  # terminate. The module's own functions start out visited: `calls/2`
  # already collected their definitions.

  defp follow(graph, entry, clauses, defining, {names, visited}) do
    sites = for clause <- clauses, site <- sites(clause.body, entry), do: site

    Enum.reduce_while(sites, {:ok, names, visited}, fn site, {:ok, names, visited} ->
      step(graph, resolve(graph, entry, site), defining, {names, visited})
    end)
  end

  defp step(_graph, :ignore, _defining, {names, visited}), do: {:cont, {:ok, names, visited}}
  defp step(_graph, :unresolved, _defining, _acc), do: {:halt, :error}

  defp step(graph, {:ok, target, key}, defining, {names, visited}) do
    if MapSet.member?(visited, {target.name, key}),
      do: {:cont, {:ok, names, visited}},
      else: visit(graph, target, key, defining, {names, visited})
  end

  defp visit(graph, target, key, defining, {names, visited}) do
    clauses = Map.fetch!(target.functions, key)

    found =
      for clause <- clauses, {_fun, name, _meta} <- body_calls(clause.body, defining), do: name

    visited = MapSet.put(visited, {target.name, key})

    case follow(graph, target, clauses, defining, {found ++ names, visited}) do
      {:ok, _names, _visited} = result -> {:cont, result}
      :error -> {:halt, :error}
    end
  end

  # A call resolves to a project function to follow, to `:unresolved` when
  # it hands the socket to code the analysis cannot read, or to `:ignore`.
  # Local calls the module and its imports do not define come from
  # Phoenix or a `use` macro and are ignored.
  defp resolve(graph, _entry, {:remote, module, fun, arity, socket?}) do
    target = module && Graph.module(graph, module)
    key = target && function_key(target, fun, arity)

    cond do
      key -> {:ok, target, key}
      not socket? -> :ignore
      module && is_nil(target) && library?(module) -> :ignore
      true -> :unresolved
    end
  end

  defp resolve(graph, entry, {:local, fun, arity, _socket?}) do
    imported =
      for module <- entry.imports,
          is_atom(module),
          target = Graph.module(graph, module),
          do: target

    Enum.find_value([entry | imported], :ignore, fn target ->
      if key = function_key(target, fun, arity), do: {:ok, target, key}
    end)
  end

  # The `{fun, arity}` key of the function a call with `arity` arguments
  # reaches, counting default arguments.
  defp function_key(%Entry{functions: functions}, fun, arity) do
    Enum.find_value(functions, fn
      {{^fun, ^arity} = key, _clauses} ->
        key

      {{^fun, full} = key, [clause | _]} when full > arity ->
        if Enum.count(clause.args, &match?({:\\, _, _}, &1)) >= full - arity, do: key

      _function ->
        nil
    end)
  end

  # Phoenix and the Elixir and Erlang standard libraries take sockets
  # without defining names the analysis cannot see.
  defp library?(module) do
    String.starts_with?(Atom.to_string(module), "Elixir.Phoenix.") or
      match?(
        {:ok, app} when app in [:elixir, :stdlib, :kernel],
        :application.get_application(module)
      )
  end

  # `{:remote, module, fun, arity, socket?}` and `{:local, fun, arity,
  # socket?}` for each call in `body`. Pipes are expanded, so `arity`
  # counts the piped argument. `module` is `nil` when the call names its
  # module dynamically; `socket?` holds when an argument is `socket` or a
  # call chain that starts at it.
  defp sites(body, entry) do
    body
    |> Macro.prewalk(&unpipe/1)
    |> Macro.prewalker()
    |> Enum.flat_map(&site(&1, entry))
  end

  defp unpipe({:|>, _, [left, {fun, meta, args}]}) when is_list(args),
    do: {fun, meta, [left | args]}

  defp unpipe(node), do: node

  # `socket.assigns` and other field reads parse as remote calls without
  # parentheses.
  defp site({{:., _, [module, fun]}, meta, args}, entry) when is_atom(fun) and is_list(args) do
    if args == [] and meta[:no_parens],
      do: [],
      else: [{:remote, module_of(module, entry), fun, length(args), Enum.any?(args, &socket?/1)}]
  end

  defp site({fun, _meta, args}, _entry) when is_atom(fun) and is_list(args) do
    if special?(fun, length(args)),
      do: [],
      else: [{:local, fun, length(args), Enum.any?(args, &socket?/1)}]
  end

  defp site(_node, _entry), do: []

  defp module_of(module, _entry) when is_atom(module), do: module
  defp module_of({:__MODULE__, _, context}, entry) when is_atom(context), do: entry.name

  defp module_of({:__aliases__, _, _} = ast, entry) do
    case ModuleIndex.expand(ast, entry.aliases) do
      module when is_atom(module) -> module
      _dynamic -> nil
    end
  end

  defp module_of(_dynamic, _entry), do: nil

  defp special?(fun, arity),
    do: Macro.special_form?(fun, arity) or Macro.operator?(fun, arity) or fun in [:fn, :->, :\\]

  defp socket?({:socket, _, context}) when is_atom(context), do: true

  defp socket?({{:., _, [_module, fun]}, meta, [first | _]}) when is_atom(fun),
    do: not Keyword.get(meta, :no_parens, false) and socket?(first)

  defp socket?({fun, _, [first | _]}) when is_atom(fun),
    do: not special?(fun, 1) and socket?(first)

  defp socket?(_arg), do: false

  defp uses(graph, entry, calls, spec) do
    reads =
      for template <- Components.render_templates(graph, entry.name),
          {name, span} <- reads(template, spec.assign),
          do: {name, span, Anchors.for_template(graph, template, span)}

    used =
      for {function, name, meta} <- calls,
          function in spec.using,
          is_atom(name) do
        span = Span.covering(entry.file, meta, Atom.to_string(function))
        {name, span, span}
      end

    reads ++ used
  end

  # ── Template reads ──

  defp reads(%Template{file: file} = template, assign) do
    for ast <- Reads.expressions(template),
        node <- Macro.prewalker(ast),
        read <- collect_read(node, assign, file),
        do: read
  end

  defp collect_read({{:., _, [{:@, meta, [{assign, _, context}]}, name]}, _, []}, assign, file)
       when is_atom(context) and is_atom(name),
       do: [{name, Span.covering(file, meta, "@#{assign}.#{name}")}]

  defp collect_read(
         {{:., _, [Access, :get]}, _, [{:@, meta, [{assign, _, context}]}, name]},
         assign,
         file
       )
       when is_atom(context) and is_atom(name),
       do: [{name, Span.covering(file, meta, "@#{assign}[:#{name}]")}]

  defp collect_read(_node, _assign, _file), do: []

  # ── Calls ──

  # `{function, name, meta}` for every call to `functions` in the module's
  # functions; a name that is not a literal atom comes back as
  # `{:dynamic}`.
  defp calls(entry, functions) do
    for clause <- ModuleIndex.clauses(entry),
        call <- body_calls(clause.body, functions),
        do: call
  end

  defp body_calls(body, functions) do
    for {function, meta, args} <- Calls.named(body, functions),
        call <- call(function, meta, args),
        do: call
  end

  defp call(function, meta, [name | _]) when is_atom(name) and not is_nil(name),
    do: [{function, name, meta}]

  defp call(function, meta, [_socket, name | _]) when is_atom(name) and not is_nil(name),
    do: [{function, name, meta}]

  defp call(function, meta, [_first, _second | _]), do: [{function, {:dynamic}, meta}]
  defp call(_function, _meta, _args), do: []
end
