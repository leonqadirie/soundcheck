defmodule Soundcheck.Elixir.ModuleIndex do
  @moduledoc false
  # Per-file Elixir facts read from the source AST: every module the file
  # defines, with what soundcheck needs from it before any compilation.
  #
  # The source AST must come from `Code.string_to_quoted/2` with
  # `columns: true` and `token_metadata: true`, as Credo parses source files.
  #
  # Kinds come from `use` calls and are heuristic: `use Phoenix.LiveView`
  # and `use MyAppWeb, :live_view` both mark a LiveView. The semantic tier
  # confirms kinds through `Soundcheck.Beam.Introspect.live/1`.

  alias Soundcheck.Elixir.Names
  alias Soundcheck.Elixir.Sigils
  alias Soundcheck.Heex.Template
  alias Soundcheck.Span

  defmodule Entry do
    @moduledoc false
    # Source facts for one `defmodule`.
    @enforce_keys [:name, :file, :span]
    defstruct [
      :name,
      :file,
      :span,
      kind: :other,
      uses: [],
      aliases: %{},
      imports: [],
      embed_templates: [],
      functions: %{},
      components: %{},
      templates: [],
      live_routes: [],
      on_mount: []
    ]

    @type kind :: :live_view | :live_component | :component | :router | :other

    @type t :: %__MODULE__{
            name: module() | nil,
            file: Path.t(),
            span: Span.t(),
            kind: kind(),
            uses: [%{module: module() | Macro.t(), args: [Macro.t()], line: pos_integer()}],
            aliases: %{atom() => module()},
            imports: [module()],
            embed_templates: [
              %{
                pattern: String.t(),
                root: String.t() | nil,
                suffix: String.t(),
                line: pos_integer(),
                column: pos_integer()
              }
            ],
            functions: %{{atom(), arity()} => [Soundcheck.Elixir.ModuleIndex.Clause.t()]},
            components: %{atom() => Soundcheck.Elixir.ModuleIndex.declarations()},
            templates: [Template.t()],
            live_routes: [%{path: String.t(), line: pos_integer(), column: pos_integer()}],
            on_mount: [Soundcheck.Elixir.ModuleIndex.hook()]
          }
  end

  defmodule Clause do
    @moduledoc false
    # One `def` or `defp` clause as written in source.
    @enforce_keys [:kind, :line, :column, :args, :guards, :body]
    defstruct [:kind, :line, :column, :args, :guards, :body]

    @type t :: %__MODULE__{
            kind: :def | :defp,
            line: pos_integer(),
            column: pos_integer(),
            args: [Macro.t()],
            guards: [Macro.t()],
            body: Macro.t()
          }
  end

  @type clause :: Clause.t()

  defmodule Declaration do
    @moduledoc false
    # One `attr` or `slot` declaration as written in source.
    @enforce_keys [:name, :line, :type, :opts]
    defstruct [:name, :line, :type, :opts]

    @type t :: %__MODULE__{
            name: atom(),
            line: pos_integer(),
            type: atom() | Macro.t() | nil,
            opts: keyword() | Macro.t()
          }
  end

  defmodule Hook do
    @moduledoc false
    # An `on_mount` hook the source declares: through `on_mount/1` in a
    # LiveView or LiveComponent, or the `:on_mount` option of a router's
    # `live_session`. `arg` is `:default` for a bare module, and the span
    # covers the module alias.
    @enforce_keys [:module, :arg, :span]
    defstruct [:module, :arg, :span]

    @type t :: %__MODULE__{module: module() | Macro.t(), arg: term(), span: Soundcheck.Span.t()}
  end

  @type declaration :: Declaration.t()
  @type hook :: Hook.t()

  @type declarations :: %{attrs: [declaration()], slots: [declaration()], line: pos_integer()}

  @kinds %{
    Phoenix.LiveView => :live_view,
    Phoenix.LiveComponent => :live_component,
    Phoenix.Component => :component,
    Phoenix.Router => :router
  }

  @use_kinds %{
    live_view: :live_view,
    live_component: :live_component,
    html: :component,
    component: :component,
    router: :router
  }

  @doc "Every function clause `entry` defines, across all functions."
  @spec clauses(Entry.t()) :: [Clause.t()]
  def clauses(%Entry{functions: functions}), do: functions |> Map.values() |> List.flatten()

  @doc "Indexes every module `ast` defines, in source order."
  @spec modules(Macro.t(), String.t(), Path.t()) :: [Entry.t()]
  def modules(ast, source, file) do
    templates = Sigils.templates(ast, source, file)

    {scoped, _env} = ast |> statements() |> with_envs(nil, Code.env_for_eval([]))

    scoped
    |> collect_scoped(nil, file, [])
    |> Enum.reverse()
    |> Enum.map(fn module ->
      %{module | templates: Enum.filter(templates, &owned_by?(&1, module.name))}
    end)
  end

  defp owned_by?(%Template{owner: {name, _fun}}, name) when not is_nil(name), do: true
  defp owned_by?(_template, _name), do: false

  # ── Modules ──

  # Each statement carries the lexical environment in force after it, so a
  # nested module starts from the aliases its parent defined above it,
  # including the alias `defmodule` itself defines for the nested module.

  defp collect_scoped(scoped, parent, file, acc) do
    Enum.reduce(scoped, acc, fn {statement, env}, acc ->
      collect_modules(statement, parent, file, env, acc)
    end)
  end

  defp collect_modules({:defmodule, meta, [name, [{_do, body}]]}, parent, file, env, acc) do
    module_name = Names.module_name(name, parent)
    {scoped, module_env} = body |> statements() |> with_envs(module_name, env)
    module = index_module(module_name, meta, scoped, module_env, file)
    collect_scoped(scoped, module_name, file, [module | acc])
  end

  defp collect_modules({_form, _meta, args}, parent, file, env, acc) when is_list(args),
    do: collect_modules(args, parent, file, env, acc)

  defp collect_modules(list, parent, file, env, acc) when is_list(list),
    do: Enum.reduce(list, acc, &collect_modules(&1, parent, file, env, &2))

  defp collect_modules({left, right}, parent, file, env, acc) do
    acc = collect_modules(left, parent, file, env, acc)
    collect_modules(right, parent, file, env, acc)
  end

  defp collect_modules(_leaf, _parent, _file, _env, acc), do: acc

  defp index_module(name, meta, scoped, env, file) do
    start = {meta[:line], meta[:column] || 1}
    stop = if meta[:end], do: {meta[:end][:line], meta[:end][:column] + 3}, else: start

    statements = Enum.map(scoped, fn {statement, _env} -> statement end)

    module = %Entry{
      name: name,
      file: file,
      span: Span.new(file, start, stop),
      aliases: alias_map(env),
      uses: uses(scoped),
      imports: for({{:import, _, [target | _]}, env} <- scoped, do: expand_in(target, env)),
      embed_templates: embedded_templates(statements)
    }

    {functions, components} = functions(statements)
    kind = kind(module.uses)
    live_routes = if kind == :router, do: live_declarations(statements, "/"), else: []

    %{
      module
      | kind: kind,
        functions: functions,
        components: components,
        live_routes: live_routes,
        on_mount: hooks(kind, scoped, file)
    }
  end

  defp statements({:__block__, _meta, statements}), do: statements
  defp statements(statement), do: [statement]

  # ── Aliases, uses, kinds ──

  # Pairs each statement with the environment after it. `Macro.Env` keeps
  # the aliases, so shadowing and prefix expansion follow the compiler.
  defp with_envs(statements, module_name, env) do
    Enum.map_reduce(statements, env, fn statement, env ->
      env = define(statement, env, module_name)
      {{statement, env}, env}
    end)
  end

  defp define({:alias, meta, [{:__aliases__, _, segments} | opts]}, env, module_name),
    do: define_alias(env, meta, segments, as(opts), module_name)

  defp define(
         {:alias, meta, [{{:., _, [{:__aliases__, _, base}, :{}]}, _, children} | _opts]},
         env,
         module_name
       ) do
    Enum.reduce(children, env, fn
      {:__aliases__, _, segments}, env ->
        define_alias(env, meta, base ++ segments, [], module_name)

      _child, env ->
        env
    end)
  end

  # `defmodule Child` inside `Parent` aliases `Child` to `Parent.Child`.
  defp define({:defmodule, meta, [{:__aliases__, _, [first | _]} | _]}, env, module_name)
       when is_atom(first) and not is_nil(module_name),
       do: put_alias(env, meta, Module.concat(module_name, first), as: Module.concat([first]))

  defp define(_statement, env, _module_name), do: env

  defp define_alias(env, meta, segments, as, module_name) do
    segments = normalize_module_segment(segments)

    if Enum.all?(segments, &is_atom/1),
      do: put_alias(env, meta, resolve(segments, env, module_name), as),
      else: env
  end

  # Without `:as`, `Macro.Env.define_alias/4` names the alias after the
  # module's last segment.
  defp put_alias(env, meta, module, opts) do
    case Macro.Env.define_alias(env, meta, module, [trace: false] ++ opts) do
      {:ok, env} -> env
      {:error, _reason} -> env
    end
  end

  defp as([opts]) when is_list(opts) do
    case Keyword.keyword?(opts) && opts[:as] do
      {:__aliases__, _, [as]} when is_atom(as) -> [as: Module.concat([as])]
      _default -> []
    end
  end

  defp as(_opts), do: []

  # `alias __MODULE__.Child` parses the leading `__MODULE__` as a call node.
  defp normalize_module_segment([{:__MODULE__, _meta, context} | rest]) when is_atom(context),
    do: [:__MODULE__ | rest]

  defp normalize_module_segment(segments), do: segments

  defp resolve([:__MODULE__ | rest], _env, module_name) when not is_nil(module_name),
    do: Module.concat([module_name | rest])

  defp resolve(segments, env, _module_name) do
    case Macro.Env.expand_alias(env, [], segments, trace: false) do
      {:alias, module} -> module
      :error -> Module.concat(segments)
    end
  end

  # The environment's aliases keyed by their short name, as `expand/2` reads them.
  defp alias_map(env) do
    Map.new(env.aliases, fn {short, full} ->
      "Elixir." <> name = Atom.to_string(short)
      {String.to_existing_atom(name), full}
    end)
  end

  defp expand_in({:__aliases__, _meta, segments} = ast, env) do
    if Enum.all?(segments, &is_atom/1), do: resolve(segments, env, nil), else: ast
  end

  defp expand_in(ast, _env), do: ast

  defp expand_segments([first | rest] = segments, aliases) do
    case aliases do
      %{^first => full} -> Module.concat([full | rest])
      _none -> Module.concat(segments)
    end
  end

  @doc """
  Expands an alias AST against `aliases`. Returns the module atom, or the
  AST itself when the alias is not a literal.
  """
  @spec expand(Macro.t(), %{atom() => module()}) :: module() | Macro.t()
  def expand({:__aliases__, _meta, segments} = ast, aliases) do
    if Enum.all?(segments, &is_atom/1), do: expand_segments(segments, aliases), else: ast
  end

  def expand(atom, _aliases) when is_atom(atom), do: atom
  def expand(ast, _aliases), do: ast

  defp uses(scoped) do
    for {{:use, meta, [target | args]}, env} <- scoped do
      %{module: expand_in(target, env), args: args, line: meta[:line]}
    end
  end

  defp kind(uses) do
    Enum.find_value(uses, :other, fn
      %{module: module, args: [kind | _]} when is_atom(module) and is_atom(kind) ->
        Map.get(@kinds, module) || Map.get(@use_kinds, kind)

      %{module: module} when is_atom(module) ->
        Map.get(@kinds, module)

      _use ->
        nil
    end)
  end

  # `embed_templates pattern, root: dir, suffix: text`. A call whose pattern
  # or options are not literals is left out: source does not say where its
  # templates are or what their functions are called.
  defp embedded_templates(statements) do
    for {:embed_templates, meta, [pattern | rest]} <- statements,
        is_binary(pattern),
        {:ok, root, suffix} <- [embed_options(rest)] do
      %{pattern: pattern, root: root, suffix: suffix, line: meta[:line], column: meta[:column]}
    end
  end

  defp embed_options([]), do: {:ok, nil, ""}

  defp embed_options([opts]) when is_list(opts) do
    with true <- Keyword.keyword?(opts),
         root when is_binary(root) or is_nil(root) <- Keyword.get(opts, :root),
         suffix when is_binary(suffix) <- Keyword.get(opts, :suffix, "") do
      {:ok, root, suffix}
    else
      _not_literal -> :error
    end
  end

  defp embed_options(_args), do: :error

  # ── Router declarations ──
  #
  # `live` calls with literal paths, through `scope`, `live_session`, and
  # any other block macro (`ash_authentication_live_session`), with the
  # scope path prefixes applied as Phoenix applies them.

  defp live_declarations(statements, prefix) do
    Enum.flat_map(statements, fn
      {:live, meta, [path | _]} when is_binary(path) ->
        [%{path: join_path(prefix, path), line: meta[:line], column: meta[:column]}]

      {block_form, _, args} when is_atom(block_form) and is_list(args) ->
        case do_block(args) do
          nil ->
            []

          block ->
            live_declarations(statements(block), join_path(prefix, scope_path(block_form, args)))
        end

      _statement ->
        []
    end)
  end

  # ── on_mount declarations ──

  defp hooks(:router, scoped, file),
    do: Enum.flat_map(scoped, fn {statement, env} -> router_hooks(statement, env, file) end)

  defp hooks(_kind, scoped, file) do
    for {{:on_mount, _, [declared]}, env} <- scoped, hook <- hook(declared, env, file), do: hook
  end

  defp router_hooks({form, _, args}, env, file) when is_atom(form) and is_list(args) do
    nested =
      if block = do_block(args),
        do: block |> statements() |> Enum.flat_map(&router_hooks(&1, env, file)),
        else: []

    session = if live_session?(form), do: session_hooks(args), else: []
    Enum.flat_map(session, &hook(&1, env, file)) ++ nested
  end

  defp router_hooks(_statement, _env, _file), do: []

  # `live_session` and wrappers such as `ash_authentication_live_session`.
  defp live_session?(form), do: form |> Atom.to_string() |> String.ends_with?("live_session")

  defp session_hooks(args) do
    case Enum.find_value(args, &(Keyword.keyword?(&1) && &1[:on_mount])) do
      hooks when is_list(hooks) -> hooks
      nil -> []
      hook -> [hook]
    end
  end

  defp hook({{:__aliases__, _, _} = module, arg}, env, file), do: hook(module, arg, env, file)

  defp hook({:__aliases__, _, _} = module, env, file), do: hook(module, :default, env, file)

  defp hook(_declared, _env, _file), do: []

  defp hook({:__aliases__, meta, _} = module, arg, env, file) do
    start = {meta[:line], meta[:column]}
    stop = {meta[:line], meta[:column] + String.length(Macro.to_string(module))}
    [%Hook{module: expand_in(module, env), arg: arg, span: Span.new(file, start, stop)}]
  end

  defp do_block(args), do: Enum.find_value(args, &(Keyword.keyword?(&1) && &1[:do]))

  defp scope_path(:scope, [path | _]) when is_binary(path), do: path

  defp scope_path(:scope, args),
    do: Enum.find_value(args, "", &(Keyword.keyword?(&1) && is_binary(&1[:path]) && &1[:path]))

  defp scope_path(_block_form, _args), do: ""

  defp join_path(prefix, path) do
    case String.split(prefix, "/", trim: true) ++ String.split(path, "/", trim: true) do
      [] -> "/"
      segments -> Enum.map_join(segments, &("/" <> &1))
    end
  end

  # ── Functions and component declarations ──
  #
  # `attr` and `slot` declarations accumulate and attach to the next `def`
  # or `defp`, as Phoenix.Component attaches them. Declarations and clauses
  # accumulate in reverse and are put back in source order at the end.

  defp functions(statements) do
    initial = {%{}, %{}, %{attrs: [], slots: [], line: nil}}

    {functions, components, _pending} =
      Enum.reduce(statements, initial, fn statement, {functions, components, pending} ->
        case statement do
          {:attr, meta, [name | rest]} when is_atom(name) ->
            declaration = declaration(name, meta, rest)

            {functions, components,
             %{pending | attrs: [declaration | pending.attrs], line: pending.line || meta[:line]}}

          {:slot, meta, [name | rest]} when is_atom(name) ->
            declaration = declaration(name, meta, rest)

            {functions, components,
             %{pending | slots: [declaration | pending.slots], line: pending.line || meta[:line]}}

          {kind, meta, [head | body]} when kind in [:def, :defp] ->
            add_function(functions, components, pending, kind, meta, head, body)

          _statement ->
            {functions, components, pending}
        end
      end)

    {Map.new(functions, fn {key, clauses} -> {key, Enum.reverse(clauses)} end), components}
  end

  defp declaration(name, meta, rest),
    do: %Declaration{
      name: name,
      line: meta[:line],
      type: declaration_type(rest),
      opts: declaration_opts(rest)
    }

  # `attr :name, :type, opts` and `slot :name, opts`: the type is the first
  # argument after the name unless that argument is the options list.
  defp declaration_type([type | _rest]) when not is_list(type), do: type
  defp declaration_type(_rest), do: nil

  defp declaration_opts([opts]) when is_list(opts), do: opts
  defp declaration_opts([_type, opts]) when is_list(opts), do: opts
  defp declaration_opts([_type, opts, _block]) when is_list(opts), do: opts
  defp declaration_opts(_rest), do: []

  defp add_function(functions, components, pending, kind, meta, head, body) do
    case head(head) do
      {name, args, guards} ->
        clause = %Clause{
          kind: kind,
          line: meta[:line],
          column: meta[:column],
          args: args,
          guards: guards,
          body: body_of(body)
        }

        functions = Map.update(functions, {name, length(args)}, [clause], &[clause | &1])

        components =
          if pending.attrs != [] or pending.slots != [] do
            declarations = %{
              pending
              | attrs: Enum.reverse(pending.attrs),
                slots: Enum.reverse(pending.slots)
            }

            Map.put_new(components, name, declarations)
          else
            components
          end

        {functions, components, %{attrs: [], slots: [], line: nil}}

      nil ->
        {functions, components, pending}
    end
  end

  defp head({:when, _meta, [head | guards]}) do
    with {name, args, []} <- head(head), do: {name, args, guards}
  end

  defp head({name, _meta, args}) when is_atom(name) and is_list(args), do: {name, args, []}
  defp head({name, _meta, context}) when is_atom(name) and is_atom(context), do: {name, [], []}
  defp head(_head), do: nil

  defp body_of([[{_do, body} | _]]), do: body
  defp body_of([]), do: nil
  defp body_of(_body), do: nil
end
