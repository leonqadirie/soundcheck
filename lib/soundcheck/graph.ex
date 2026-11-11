defmodule Soundcheck.Graph do
  @moduledoc false
  # The per-run model of a LiveView project that rules query.
  #
  # `build/2` collects the per-file front-end facts: indexed modules, every
  # template (`~H` sigils and `.heex` files), and JavaScript hook facts.
  # `Soundcheck.Graph.Link` then adds the links between files that rules
  # share, such as live routes and the render index. It adds only the links
  # the run's checks declare in `needs:`, so a run of syntactic checks never
  # reads compiled modules for them.
  #
  # A link field holds `:not_linked` until `Soundcheck.Graph.Link` fills it,
  # and its accessor raises on that value: a check that reads a link it did
  # not declare fails its first test.
  #
  # `Soundcheck.Graph.Current` holds the run's graph.

  alias Soundcheck.Elixir.ModuleIndex
  alias Soundcheck.Graph.Input
  alias Soundcheck.Heex.Parser
  alias Soundcheck.Heex.Template
  alias Soundcheck.JS.Extractor

  @links [:live_modules, :routes, :render_index, :js_helpers]

  # `modules_by_name`, `templates_by_owner`, and `templates_by_module`
  # index `modules` and `templates` for `module/2`, `templates_of/3`, and
  # `templates_of/2`, which checks call inside loops over every module.
  defstruct modules: [],
            templates: [],
            js: [],
            modules_by_name: %{},
            templates_by_owner: %{},
            templates_by_module: %{},
            live_modules: :not_linked,
            routes: :not_linked,
            render_index: :not_linked,
            js_helpers: :not_linked

  @type t :: %__MODULE__{
          modules: [ModuleIndex.Entry.t()],
          templates: [Template.t()],
          js: [Extractor.Facts.t()],
          modules_by_name: %{module() => ModuleIndex.Entry.t()},
          templates_by_owner: %{{module(), atom()} => [Template.t()]},
          templates_by_module: %{module() => [Template.t()]},
          live_modules: [{ModuleIndex.Entry.t(), :view | :component}] | :not_linked,
          routes: [route()] | :not_linked,
          render_index: render_index() | :not_linked,
          js_helpers: MapSet.t({atom(), arity()}) | :not_linked
        }

  # The graph layer sits below the Beam and analysis layers that produce
  # these two links, so it names their structs without their types.
  @typedoc "A live route, a `Soundcheck.Beam.Introspect.Route`."
  @type route :: struct()

  @typedoc "A `Soundcheck.Analysis.Components.Index`."
  @type render_index :: struct()

  @typedoc "A link between files that `Soundcheck.Graph.Link` adds on demand."
  @type link :: :live_modules | :routes | :render_index | :js_helpers

  @type input :: Input.t()

  @typedoc "The graph's module, template, and JavaScript file counts."
  @type summary :: %{
          modules: non_neg_integer(),
          templates: non_neg_integer(),
          js_files: non_neg_integer()
        }

  @default_js_paths ["assets/js"]

  @doc "Returns every link a check can declare in `needs:`."
  @spec links() :: [link()]
  def links, do: @links

  @doc "Counts the graph's modules, templates, and JavaScript files."
  @spec summary(t()) :: summary()
  def summary(%__MODULE__{} = graph),
    do: %{
      modules: length(graph.modules),
      templates: length(graph.templates),
      js_files: length(graph.js)
    }

  @doc """
  Builds a graph from parsed Elixir sources.

  Options:

    * `:js_paths` - directories scanned for `.js`/`.ts` hook sources
      (default `["assets/js"]`)
  """
  @spec build([input()], keyword()) :: t()
  def build(inputs, opts \\ []) do
    opts = Keyword.validate!(opts, js_paths: @default_js_paths)

    modules = parallel_flat_map(inputs, &ModuleIndex.modules(&1.ast, &1.source, &1.file))

    templates = Enum.flat_map(modules, & &1.templates) ++ heex_templates(modules)

    %__MODULE__{
      modules: modules,
      templates: templates,
      js: js_facts(Keyword.fetch!(opts, :js_paths)),
      modules_by_name: index_modules(modules),
      templates_by_owner: Enum.group_by(templates, & &1.owner),
      templates_by_module: index_templates_by_module(templates)
    }
  end

  # The first entry wins when two modules share a name, as `Enum.find/2`
  # did before the index existed.
  defp index_modules(modules) do
    Enum.reduce(modules, %{}, fn
      %ModuleIndex.Entry{name: nil}, acc -> acc
      %ModuleIndex.Entry{name: name} = entry, acc -> Map.put_new(acc, name, entry)
    end)
  end

  defp index_templates_by_module(templates) do
    templates
    |> Enum.filter(&match?(%Template{owner: {_module, _fun}}, &1))
    |> Enum.group_by(fn %Template{owner: {module, _fun}} -> module end)
  end

  @doc "Returns the indexed module named `name`, or `nil`."
  @spec module(t(), module()) :: ModuleIndex.Entry.t() | nil
  def module(%__MODULE__{modules_by_name: modules}, name), do: Map.get(modules, name)

  @doc "Returns `{entry, clause}` for every function clause of every indexed module."
  @spec clauses(t()) :: [{ModuleIndex.Entry.t(), ModuleIndex.Clause.t()}]
  def clauses(%__MODULE__{modules: modules}),
    do: for(entry <- modules, clause <- ModuleIndex.clauses(entry), do: {entry, clause})

  @doc "Returns the templates whose owner is `{module, fun}`."
  @spec templates_of(t(), module(), atom()) :: [Template.t()]
  def templates_of(%__MODULE__{templates_by_owner: templates}, module, fun),
    do: Map.get(templates, {module, fun}, [])

  @doc """
  Returns `{entry, kind}` for every indexed module whose compiled form is a
  LiveView (`:view`) or LiveComponent (`:component`). Needs `:live_modules`.
  """
  @spec live_modules(t()) :: [{ModuleIndex.Entry.t(), :view | :component}]
  def live_modules(%__MODULE__{} = graph), do: linked!(graph, :live_modules)

  @doc "Returns the live routes of every router in the graph. Needs `:routes`."
  @spec routes(t()) :: [route()]
  def routes(%__MODULE__{} = graph), do: linked!(graph, :routes)

  @doc """
  Returns the render index: component call sites by callee, and the
  functions that hand each callee their assigns whole. Needs `:render_index`.
  """
  @spec render_index(t()) :: render_index()
  def render_index(%__MODULE__{} = graph), do: linked!(graph, :render_index)

  @doc """
  Returns the `{name, arity}` of every project function that builds `JS`
  commands without `JS.push`. Needs `:js_helpers`.
  """
  @spec js_helpers(t()) :: MapSet.t({atom(), arity()})
  def js_helpers(%__MODULE__{} = graph), do: linked!(graph, :js_helpers)

  defp linked!(graph, link) do
    case Map.fetch!(graph, link) do
      :not_linked ->
        raise ArgumentError,
              "the graph has no #{inspect(link)} link; add it to the check's `needs:` option"

      value ->
        value
    end
  end

  @doc "Returns the templates any function of `module` renders, in graph order."
  @spec templates_of(t(), module()) :: [Template.t()]
  def templates_of(%__MODULE__{templates_by_module: templates}, module),
    do: Map.get(templates, module, [])

  # ── .heex files ──
  #
  # `embed_templates "pattern"` embeds `<root>/pattern.heex`, where the root
  # is the calling file's directory or the `:root` option relative to it,
  # and names each function after the file's basename without extensions,
  # plus the `:suffix` option. A LiveView without `render/1` renders
  # `<dir>/<underscored last segment>.html.heex`.

  defp heex_templates(modules) do
    modules
    |> Enum.flat_map(&heex_files/1)
    |> Enum.uniq_by(fn {file, _owner} -> file end)
    |> parallel_flat_map(fn {file, owner} ->
      with_source(file, &Parser.parse(&1, file: file, owner: owner))
    end)
  end

  defp heex_files(%ModuleIndex.Entry{name: nil}), do: []

  defp heex_files(%ModuleIndex.Entry{} = module) do
    dir = Path.dirname(module.file)

    embedded =
      for %ModuleIndex.EmbedTemplates{pattern: pattern, root: root, suffix: suffix} <-
            module.embed_templates,
          file <- Path.wildcard(Path.join(embed_root(dir, root), pattern <> ".heex")),
          do: {file, {module.name, function_name(file, suffix)}}

    embedded ++ colocated(module, dir)
  end

  # Template paths keep the form of the module's path: relative to the
  # current directory when the module's is.
  defp embed_root(dir, nil), do: dir

  defp embed_root(dir, root) do
    expanded = Path.expand(root, dir)
    if Path.type(dir) == :absolute, do: expanded, else: Path.relative_to_cwd(expanded)
  end

  defp colocated(%ModuleIndex.Entry{kind: :live_view} = module, dir) do
    file = Path.join(dir, colocated_filename(module.name))

    if not Map.has_key?(module.functions, {:render, 1}) and File.regular?(file),
      do: [{file, {module.name, :render}}],
      else: []
  end

  defp colocated(_module, _dir), do: []

  defp colocated_filename(module_name) do
    [last | _] = module_name |> Module.split() |> Enum.reverse()
    Macro.underscore(last) <> ".html.heex"
  end

  # The function an embedded template defines, named as
  # `Phoenix.Component.embed_templates/2` names it: the file's basename
  # without extensions, plus the suffix. Compiling the project creates the
  # same atom, and their number is bounded by the template files on disk.
  defp function_name(file, suffix) do
    name = file |> Path.basename() |> Path.rootname() |> Path.rootname()
    # reach:disable-next-line unsafe_atom_creation
    String.to_atom(name <> suffix)
  end

  # ── JavaScript ──

  defp js_facts(paths) do
    paths
    |> Enum.flat_map(&js_files/1)
    |> parallel_flat_map(&js_file_facts/1)
  end

  defp js_files(path) do
    path
    |> Path.join("**/*.{js,ts,mjs}")
    |> Path.wildcard()
    |> Enum.reject(&String.contains?(&1, ["/node_modules/", "/vendor/"]))
  end

  defp js_file_facts(file), do: with_source(file, &Extractor.extract(&1, file: file))

  # Wraps `fun.(source)` in a list, or returns `[]` when `file` cannot be
  # read (a broken symlink, a directory named `x.js`), so one unreadable
  # file does not abort the whole graph build.
  defp with_source(file, fun) do
    case File.read(file) do
      {:ok, source} -> [fun.(source)]
      {:error, _reason} -> []
    end
  end

  # Maps `fun` over `items` in one task each and concatenates the results
  # in input order. A front end reads one file at a time, so the files
  # parse in parallel.
  defp parallel_flat_map(items, fun) do
    items
    |> Task.async_stream(fun, ordered: true, timeout: :infinity)
    |> Enum.flat_map(fn {:ok, results} -> results end)
  end
end
