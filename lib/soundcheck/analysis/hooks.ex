defmodule Soundcheck.Analysis.Hooks do
  @moduledoc false
  # The project's JavaScript hooks: what `LiveSocket` registers, what
  # templates reference with `phx-hook`, and where each hook is defined.
  #
  # The registry starts from every `new LiveSocket(...)` and follows the
  # forms `Soundcheck.JS.Extractor` resolves within a file, plus imports:
  #
  #   * `import {hooks} from "phoenix-colocated/<app>"` registers every
  #     colocated hook (`<script :type={ColocatedHook} name=".Name">`) under
  #     LiveView's name `"#{inspect(module)}.Name"`;
  #   * a relative import (`import Hooks from "./hooks"`) resolves to that
  #     file's export, one level deep, plus local member assignments
  #     (`Hooks.Chart = ...`) on the imported binding;
  #   * a relative namespace import (`import * as hooks from "./hooks"`)
  #     registers every named export of that file;
  #   * anything else keeps the registry open, with the reason.
  #
  # `phx-hook=".Name"` in a template owned by `module` refers to the
  # colocated hook `"#{inspect(module)}.Name"`, the rewrite LiveView applies
  # at compile time.

  alias Soundcheck.Graph
  alias Soundcheck.Heex.KeywordAttrs
  alias Soundcheck.Heex.Node
  alias Soundcheck.Heex.Template
  alias Soundcheck.Heex.Walker
  alias Soundcheck.JS.Extractor
  alias Soundcheck.JS.Extractor.Facts
  alias Soundcheck.Span

  @js_extensions ["", ".js", ".ts", ".mjs", "/index.js", "/index.ts"]

  @type definition ::
          {:socket, Facts.t(), Extractor.ref()}
          | {:colocated, Template.t(), Facts.t()}

  defmodule Registry do
    @moduledoc false
    # The hooks the project registers with `LiveSocket`, by name. `socket?`
    # is `false` when no JavaScript file constructs a `LiveSocket`; `open`
    # lists the reasons the names may be incomplete.
    @enforce_keys [:socket?]
    defstruct [:socket?, names: %{}, open: []]

    @type t :: %__MODULE__{
            socket?: boolean(),
            names: %{String.t() => Soundcheck.Analysis.Hooks.definition()},
            open: [term()]
          }
  end

  @type registry :: Registry.t()

  defmodule Usage do
    @moduledoc false
    # A `phx-hook` attribute: the hook name, qualified for colocated hooks,
    # or `:dynamic` when the value is an expression.
    @enforce_keys [:name, :template, :span]
    defstruct [:name, :template, :span]

    @type t :: %__MODULE__{
            name: String.t() | :dynamic,
            template: Template.t(),
            span: Span.t()
          }
  end

  @type usage :: Usage.t()

  @doc "Builds the hook registry for the whole project."
  @spec registry(Graph.t()) :: registry()
  def registry(%Graph{js: js} = graph) do
    sockets = Enum.filter(js, &(&1.live_sockets != []))
    by_path = Map.new(js, &{Path.expand(&1.file), &1})
    colocated = colocated(graph)

    Enum.reduce(sockets, %Registry{socket?: sockets != []}, fn facts, acc ->
      %Extractor.Names{names: names, open: open} = Extractor.registry(facts)
      acc = add_names(acc, facts, names)
      Enum.reduce(open, acc, &resolve_open(&1, facts, &2, by_path, colocated))
    end)
  end

  @doc """
  Returns the events a registered hook pushes and handles, or `:unknown`
  when its definition does not resolve to an object literal.
  """
  @spec events(Graph.t(), definition()) ::
          {:ok, Extractor.hook_events()} | :unknown
  def events(_graph, {:colocated, _template, facts}) do
    case facts.exports do
      %{default: {:object, id}} -> {:ok, Extractor.events_in(facts, id)}
      _other -> :unknown
    end
  end

  def events(%Graph{js: js}, {:socket, facts, ref}) do
    by_path = Map.new(js, &{Path.expand(&1.file), &1})

    case object_of(facts, ref, by_path, 4) do
      {:ok, owner, id} -> {:ok, Extractor.events_in(owner, id)}
      :error -> :unknown
    end
  end

  # Follows a ref through bindings and relative imports to an object literal,
  # at most `depth` hops.
  defp object_of(facts, {:object, id}, _by_path, _depth), do: {:ok, facts, id}
  defp object_of(_facts, _ref, _by_path, 0), do: :error

  defp object_of(facts, {:ident, name}, by_path, depth) do
    case {facts.bindings, facts.imports} do
      {%{^name => ref}, _imports} ->
        object_of(facts, ref, by_path, depth - 1)

      {_bindings, %{^name => {"." <> _ = source, imported}}} ->
        with {:ok, target} <- import_target(facts.file, source, by_path),
             {:ok, ref} <- Map.fetch(target.exports, imported) do
          object_of(target, ref, by_path, depth - 1)
        end

      _unresolved ->
        :error
    end
  end

  defp object_of(_facts, _ref, _by_path, _depth), do: :error

  @doc """
  Returns every event name the project's JavaScript listens for: literal
  `handleEvent` calls in hooks (colocated ones included) and `phx:` window
  listeners.
  """
  @spec listened_events(Graph.t(), registry()) :: MapSet.t(String.t())
  def listened_events(%Graph{js: js}, registry) do
    colocated = for {_name, {:colocated, _template, facts}} <- registry.names, do: facts

    for facts <- js ++ colocated,
        event <-
          Enum.map(facts.handles, & &1.event) ++
            Enum.map(facts.window_listeners, &{:literal, &1.event}),
        {:literal, name} <- [event],
        into: MapSet.new(),
        do: name
  end

  @doc """
  Returns every `phx-hook` reference in the project's templates, keyword
  attributes (`tag(:span, phx_hook: "Clock")`) included.
  """
  @spec usages(Graph.t()) :: [usage()]
  def usages(%Graph{templates: templates}) do
    for template <- templates,
        %Node.Element{attrs: attrs} <-
          Walker.elements(template.root) ++ KeywordAttrs.elements(template.root),
        %Node.Attr{name: "phx-hook"} = attr <- attrs do
      usage(template, attr)
    end
  end

  defp usage(template, %Node.Attr{value: {:string, name, _delimiter, span}}),
    do: %Usage{name: qualify(name, template), template: template, span: span}

  defp usage(template, %Node.Attr{span: span}),
    do: %Usage{name: :dynamic, template: template, span: span}

  defp qualify("." <> rest, %Template{owner: {module, _fun}}), do: "#{inspect(module)}.#{rest}"
  defp qualify(name, _template), do: name

  # ── Registry resolution ──

  defp add_names(acc, facts, names) do
    definitions = Map.new(names, fn {name, ref} -> {name, {:socket, facts, ref}} end)
    %{acc | names: Map.merge(acc.names, definitions)}
  end

  defp resolve_open(
         {:import, "phoenix-colocated/" <> _app, _imported},
         _facts,
         acc,
         _by_path,
         colocated
       ), do: %{acc | names: Map.merge(acc.names, colocated)}

  defp resolve_open(
         {:import, "." <> _ = source, imported} = reason,
         facts,
         acc,
         by_path,
         _colocated
       ) do
    with {:ok, target} <- import_target(facts.file, source, by_path),
         {:ok, %Extractor.Names{names: names, open: open}} <- imported_names(target, imported) do
      acc = add_names(acc, target, names)
      %{acc | open: Enum.uniq(acc.open ++ open)}
    else
      _unresolved -> %{acc | open: Enum.uniq(acc.open ++ [reason])}
    end
  end

  defp resolve_open(reason, _facts, acc, _by_path, _colocated),
    do: %{acc | open: Enum.uniq(acc.open ++ [reason])}

  # `import * as X` binds every named export; any other import binds the
  # object one export refers to.
  defp imported_names(target, :namespace), do: {:ok, Extractor.namespace_names(target)}

  defp imported_names(target, imported) do
    with {:ok, ref} <- Map.fetch(target.exports, imported),
         do: {:ok, Extractor.object_names(target, ref)}
  end

  defp import_target(importer, source, by_path) do
    base = importer |> Path.dirname() |> Path.join(source) |> Path.expand()

    Enum.find_value(@js_extensions, :error, fn extension ->
      case Map.fetch(by_path, base <> extension) do
        {:ok, facts} -> {:ok, facts}
        :error -> nil
      end
    end)
  end

  # ── Colocated hooks ──

  defp colocated(%Graph{templates: templates}) do
    for %Template{owner: {module, _fun}} = template <- templates,
        %Node.Element{tag: "script"} = script <- Walker.elements(template.root),
        colocated_hook?(script),
        {:ok, name} <- [colocated_name(script)],
        into: %{} do
      {"#{inspect(module)}.#{name}", {:colocated, template, script_facts(template, script)}}
    end
  end

  defp colocated_hook?(%Node.Element{attrs: attrs}) do
    Enum.any?(attrs, fn
      %Node.Attr{name: ":type", value: {:expr, {:__aliases__, _, segments}, _source, _span}} ->
        segments in [[:ColocatedHook], [:Phoenix, :LiveView, :ColocatedHook]]

      _attr ->
        false
    end)
  end

  defp colocated_name(%Node.Element{attrs: attrs}) do
    case Enum.find(attrs, &(&1.name == "name")) do
      %Node.Attr{value: {:string, "." <> name, _delimiter, _span}} -> {:ok, name}
      _other -> :error
    end
  end

  # Script bodies are extracted with every position at the `<script>` tag;
  # findings inside colocated hooks point at the tag that defines them.
  defp script_facts(%Template{file: file}, %Node.Element{children: children, open_span: span}) do
    source =
      Enum.map_join(children, fn
        %Node.Text{value: value} -> value
        _expression -> ""
      end)

    Extractor.extract(source, file: file, position: fn _offset -> span.start end)
  end
end
