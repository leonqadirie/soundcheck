defmodule Soundcheck.Analysis.Components do
  @moduledoc false
  # Resolves component call sites in templates to the function components or
  # LiveComponents they render, and indexes which templates call each one.
  #
  # Function component calls resolve through the caller's compiled module:
  # its expanded AST renders every function component as
  # `Phoenix.LiveView.TagEngine.component(&Mod.fun/1, ...)`, which names the
  # module even when an import arrives through `use MyAppWeb, :live_view` and
  # is invisible in source. A local call (`<.button>`) resolves to the single
  # captured function of that name; a remote call (`<Core.button>`) to the
  # captured function whose module matches the alias-expanded name.
  # `<.live_component module={Mod}>` resolves through the `module` attribute.
  # Resolution compares names as strings and creates no atoms.
  #
  # A function can also render another by handing it its assigns whole:
  # `defdelegate render(assigns), to: MyLive.Render`, or
  # `def render(assigns), do: render_page(assigns)`. Both compile to a call
  # whose only argument is the function's own assigns parameter, which
  # `render_index/1` records as a delegation and `render_templates/3`
  # follows.

  alias Soundcheck.Beam.DebugInfo
  alias Soundcheck.Elixir.ModuleIndex
  alias Soundcheck.Graph
  alias Soundcheck.Heex.Node
  alias Soundcheck.Heex.Template
  alias Soundcheck.Once

  @type callee :: {:function, module(), atom()} | {:live_component, module()}
  @type call_sites :: %{callee() => [{Template.t(), Node.Element.t()}]}
  @type delegators :: %{callee() => [{module(), atom()}]}

  defmodule Index do
    @moduledoc false
    # How templates reach one another: component call sites by callee, and
    # the functions that hand each callee their assigns whole.
    @enforce_keys [:sites, :delegators]
    defstruct [:sites, :delegators]

    @type t :: %__MODULE__{
            sites: Soundcheck.Analysis.Components.call_sites(),
            delegators: Soundcheck.Analysis.Components.delegators()
          }
  end

  @doc """
  Builds the render index: `call_sites/1` plus delegations. Each module's
  delegations decode its expanded AST, so modules read in parallel.
  """
  @spec render_index(Graph.t()) :: Index.t()
  def render_index(%Graph{} = graph) do
    project = MapSet.new(graph.modules, & &1.name)

    delegators =
      for {module, delegates} <-
            parallel_map(graph.modules, &{&1.name, delegates(&1.name, project)}),
          {fun, {target, target_fun}} <- delegates,
          reduce: %{} do
        acc ->
          Map.update(acc, {:function, target, target_fun}, [{module, fun}], &[{module, fun} | &1])
      end

    %Index{sites: call_sites(graph), delegators: delegators}
  end

  @doc """
  The templates `module.fun/1` renders: its own, and those of the
  functions it delegates its assigns to, transitively.
  """
  @spec render_templates(Graph.t(), module(), atom()) :: [Template.t()]
  def render_templates(%Graph{} = graph, module, fun \\ :render) do
    project = MapSet.new(graph.modules, & &1.name)

    {module, fun}
    |> delegated_functions(project, [])
    |> Enum.flat_map(fn {module, fun} -> Graph.templates_of(graph, module, fun) end)
  end

  defp delegated_functions({module, fun} = function, project, seen) do
    if function in seen do
      seen
    else
      for {^fun, target} <- delegates(module, project),
          reduce: seen ++ [function],
          do: (acc -> delegated_functions(target, project, acc))
    end
  end

  defp parallel_map(items, fun) do
    items
    |> Task.async_stream(fun, ordered: true, timeout: :infinity)
    |> Enum.map(fn {:ok, result} -> result end)
  end

  # `{fun, {target_module, target_fun}}` for each arity-1 function of
  # `module` that calls a project function with its own parameter as the
  # only argument. Memoized per module: every rule asks for the same edges.
  defp delegates(module, project) do
    module
    |> then(&Once.run({__MODULE__, :delegates, &1}, fn -> read_delegates(&1) end))
    |> Enum.filter(fn {_fun, {target, _target_fun}} -> MapSet.member?(project, target) end)
  end

  defp read_delegates(module) do
    case DebugInfo.definitions(module) do
      {:ok, %DebugInfo.Info{definitions: definitions}} ->
        defined =
          MapSet.new(definitions, fn {name_arity, _kind, _meta, _clauses} -> name_arity end)

        for {{fun, 1}, _kind, _meta, clauses} <- definitions,
            {_meta, [param], _guards, body} <- clauses,
            var = param_var(param),
            var != nil,
            target <- whole_param_calls(body, var, module, defined),
            target != {module, fun},
            uniq: true,
            do: {fun, target}

      {:error, _reason} ->
        []
    end
  end

  # Phoenix.Component compiles `render(assigns)` to `_ = assigns`, so an
  # underscored variable on one side is not the parameter.
  defp param_var({name, _meta, context}) when is_atom(name) and is_atom(context),
    do: if(!String.starts_with?(Atom.to_string(name), "_"), do: name)

  defp param_var({:=, _, [left, right]}), do: param_var(left) || param_var(right)
  defp param_var(_pattern), do: nil

  defp whole_param_calls(body, var, module, defined) do
    for node <- Macro.prewalker(body),
        target = whole_param_call(node, var, module, defined),
        do: target
  end

  defp whole_param_call(
         {{:., _, [target, fun]}, _meta, [{var, _, context}]},
         var,
         _module,
         _defined
       )
       when is_atom(target) and is_atom(fun) and is_atom(context), do: {target, fun}

  defp whole_param_call({fun, _meta, [{var, _, context}]}, var, module, defined)
       when is_atom(fun) and is_atom(context) do
    if MapSet.member?(defined, {fun, 1}), do: {module, fun}
  end

  defp whole_param_call(_node, _var, _module, _defined), do: nil

  @doc """
  Returns a map from each resolved callee to its call sites: the calling
  template and the component element, in source order. Calls that do not
  resolve are left out.
  """
  @spec call_sites(Graph.t()) :: call_sites()
  def call_sites(%Graph{} = graph) do
    modules = Map.new(graph.modules, &{&1.name, &1})

    # Reading captures decodes the owner's expanded AST, so owners read in
    # parallel.
    captures =
      for(%Template{owner: {owner, _fun}} <- graph.templates, uniq: true, do: owner)
      |> parallel_map(&{&1, captures(&1)})
      |> Map.new()

    sites =
      for %Template{owner: {owner, _fun}} = template <- graph.templates,
          %{} = entry <- [Map.get(modules, owner)],
          captures = Map.fetch!(captures, owner),
          element <- components(template.root),
          {:ok, callee} <- [resolve(element, entry, captures)],
          reduce: %{} do
        acc -> Map.update(acc, callee, [{template, element}], &[{template, element} | &1])
      end

    Map.new(sites, fn {callee, sites} -> {callee, Enum.reverse(sites)} end)
  end

  @doc "Resolves one component element of a template owned by `entry`."
  @spec resolve(Node.Element.t(), ModuleIndex.Entry.t(), %{String.t() => [{module(), atom()}]}) ::
          {:ok, callee()} | :error
  def resolve(
        %Node.Element{kind: :local_component, tag: ".live_component"} = element,
        entry,
        _captures
      ) do
    case Enum.find(element.attrs, &(&1.name == "module")) do
      %Node.Attr{value: {:expr, ast, _source, _span}} ->
        case ModuleIndex.expand(ast, entry.aliases) do
          module when is_atom(module) -> {:ok, {:live_component, module}}
          _dynamic -> :error
        end

      _missing ->
        :error
    end
  end

  def resolve(%Node.Element{kind: :local_component, tag: "." <> name}, _entry, captures) do
    case Map.get(captures, name, []) do
      [{module, fun}] -> {:ok, {:function, module, fun}}
      _none_or_ambiguous -> :error
    end
  end

  def resolve(%Node.Element{kind: :remote_component, tag: tag}, entry, captures) do
    {module_parts, [name]} = tag |> String.split(".") |> Enum.split(-1)
    module_name = expand_name(module_parts, entry.aliases)

    case Enum.filter(Map.get(captures, name, []), fn {module, _fun} ->
           inspect(module) == module_name
         end) do
      [{module, fun}] -> {:ok, {:function, module, fun}}
      _none_or_ambiguous -> :error
    end
  end

  def resolve(%Node.Element{}, _entry, _captures), do: :error

  # `Core.Sub` with `alias MyAppWeb.Core` expands to "MyAppWeb.Core.Sub".
  defp expand_name([first | rest] = parts, aliases) do
    case Enum.find(aliases, fn {short, _full} -> Atom.to_string(short) == first end) do
      {_short, full} -> Enum.join([inspect(full) | rest], ".")
      nil -> Enum.join(parts, ".")
    end
  end

  # Function components the compiled module renders, by function name.
  # Memoized: every template of a module and every rule that resolves call
  # sites asks for the same module's captures.
  defp captures(module),
    do: Once.run({__MODULE__, :captures, module}, fn -> read_captures(module) end)

  defp read_captures(module) do
    case DebugInfo.definitions(module) do
      {:ok, %DebugInfo.Info{definitions: definitions}} ->
        for {_name_arity, _kind, _meta, clauses} <- definitions,
            {_meta, _args, _guards, body} <- clauses,
            {mod, fun} <- component_captures(module, body),
            reduce: %{} do
          acc -> Map.update(acc, Atom.to_string(fun), [{mod, fun}], &Enum.uniq([{mod, fun} | &1]))
        end

      {:error, _reason} ->
        %{}
    end
  end

  # Remote captures (`&Mod.fun/1`) name their module; a component defined in
  # the rendering module itself expands to a local capture (`&fun/1`).
  defp component_captures(owner, body) do
    for {{:., _, [Phoenix.LiveView.TagEngine, :component]}, _meta, [capture | _]} <-
          Macro.prewalker(body),
        callee = captured(capture, owner),
        do: callee
  end

  defp captured({:&, _, [{:/, _, [{{:., _, [module, fun]}, _, []}, 1]}]}, _owner)
       when is_atom(module) and is_atom(fun), do: {module, fun}

  defp captured({:&, _, [{:/, _, [{fun, _, context}, 1]}]}, owner)
       when is_atom(fun) and is_atom(context), do: {owner, fun}

  defp captured(_capture, _owner), do: nil

  defp components(nodes) when is_list(nodes), do: Enum.flat_map(nodes, &components/1)

  defp components(%Node.Element{kind: kind, children: children} = element)
       when kind in [:local_component, :remote_component], do: [element | components(children)]

  defp components(%Node.Element{children: children}), do: components(children)

  defp components(%Node.EexBlock{clauses: clauses}),
    do: Enum.flat_map(clauses, &components(&1.children))

  defp components(_node), do: []
end
