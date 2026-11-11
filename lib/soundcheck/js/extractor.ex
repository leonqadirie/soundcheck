defmodule Soundcheck.JS.Extractor do
  @moduledoc false
  # Extracts LiveView hook facts from one JavaScript or TypeScript file.
  #
  # The extractor recognizes a narrow set of forms and records everything
  # else as opaque (`:other`) rather than guessing:
  #
  #   * object literals, with their keys and values
  #   * bindings (`const Hooks = {...}`), member assignments
  #     (`Hooks.Chart = ...`, `Hooks["Chart"] = ...`), and
  #     `Object.assign(Hooks, ...)`
  #   * imports and exports
  #   * the `hooks` option of `new LiveSocket(url, Socket, opts)`, also when
  #     the constructor is qualified (`new LiveView.LiveSocket(...)`)
  #   * `pushEvent`, `pushEventTo`, and `handleEvent` calls on `this`, a
  #     variable bound to `this`, or a field of either that the file assigns
  #     (`this.hook = hook` in a helper class, then `this.hook.pushEvent(...)`)
  #   * `window.addEventListener("phx:...")` listeners for server
  #     `push_event/3`, with a quoted or interpolation-free template name
  #
  # Resolution across files (imports, colocated hooks) happens in the graph.
  # `registry/1` resolves what one file can resolve on its own.

  alias Soundcheck.JS.Lexer
  alias Soundcheck.LineIndex
  alias Soundcheck.Span

  @type ref ::
          {:object, non_neg_integer()}
          | {:ident, String.t()}
          | {:options, {:ident, String.t()} | :other}
          | :other

  @type event :: {:literal, String.t()} | :dynamic

  defmodule Push do
    @moduledoc false
    # A `pushEvent` or `pushEventTo` call. `offset` is the byte offset of the
    # call, which `Soundcheck.JS.Extractor.events_in/2` compares against
    # object ranges.
    @enforce_keys [:kind, :event, :target, :offset, :span]
    defstruct [:kind, :event, :target, :offset, :span]

    @type t :: %__MODULE__{
            kind: :push_event | :push_event_to,
            event: Soundcheck.JS.Extractor.event(),
            target: :view | :self_el | {:selector, String.t()} | :dynamic,
            offset: non_neg_integer(),
            span: Soundcheck.Span.t()
          }
  end

  defmodule Handle do
    @moduledoc false
    # A `handleEvent` call. `offset` is the byte offset of the call.
    @enforce_keys [:event, :offset, :span]
    defstruct [:event, :offset, :span]

    @type t :: %__MODULE__{
            event: Soundcheck.JS.Extractor.event(),
            offset: non_neg_integer(),
            span: Soundcheck.Span.t()
          }
  end

  defmodule Object do
    @moduledoc false
    # An object literal, keyed in `Facts.objects` by the byte offset of its
    # `{`. `range` holds the byte offsets its braces span.
    @enforce_keys [:entries, :range, :span]
    defstruct [:entries, :range, :span]

    @type t :: %__MODULE__{
            entries: [Soundcheck.JS.Extractor.Facts.entry()],
            range: {non_neg_integer(), non_neg_integer()},
            span: Soundcheck.Span.t()
          }
  end

  defmodule LiveSocket do
    @moduledoc false
    # A `new LiveSocket(...)` call. `hooks` refers to its `hooks` option,
    # `nil` when the call passes none.
    @enforce_keys [:hooks, :span]
    defstruct [:hooks, :span]

    @type t :: %__MODULE__{
            hooks: Soundcheck.JS.Extractor.ref() | nil,
            span: Soundcheck.Span.t()
          }
  end

  defmodule WindowListener do
    @moduledoc false
    # A `window.addEventListener("phx:event", ...)` call. `event` is the
    # name without the `phx:` prefix.
    @enforce_keys [:event, :span]
    defstruct [:event, :span]

    @type t :: %__MODULE__{event: String.t(), span: Soundcheck.Span.t()}
  end

  defmodule Names do
    @moduledoc false
    # The keys an object resolves to, each with its value ref, and the
    # reasons the set may be incomplete: `{:import, source, name}` for keys
    # that come from another module, `:dynamic` for forms the extractor
    # cannot follow.
    defstruct names: %{}, open: []

    @type t :: %__MODULE__{
            names: %{String.t() => Soundcheck.JS.Extractor.ref()},
            open: [term()]
          }
  end

  defmodule HookEvents do
    @moduledoc false
    # The pushes and handled events lexically inside one hook object.
    @enforce_keys [:pushes, :handles]
    defstruct [:pushes, :handles]

    @type t :: %__MODULE__{
            pushes: [Soundcheck.JS.Extractor.Push.t()],
            handles: [Soundcheck.JS.Extractor.Handle.t()]
          }
  end

  @type push :: Push.t()
  @type handle :: Handle.t()
  @type names :: Names.t()
  @type hook_events :: HookEvents.t()

  defmodule Facts do
    @moduledoc false
    # Hook facts for one file. See `Soundcheck.JS.Extractor`.
    @enforce_keys [:file]
    defstruct [
      :file,
      objects: %{},
      bindings: %{},
      member_assigns: [],
      object_assigns: [],
      imports: %{},
      exports: %{},
      exports_open: false,
      live_sockets: [],
      pushes: [],
      handles: [],
      window_listeners: []
    ]

    @type ref :: Soundcheck.JS.Extractor.ref()

    @typedoc "One entry of an object literal. `:computed` covers every form the extractor cannot name."
    @type entry ::
            {:key, String.t(), ref()} | {:spread, ref()} | {:method, String.t()} | :computed

    @type object :: Soundcheck.JS.Extractor.Object.t()

    @type t :: %__MODULE__{
            file: Path.t(),
            objects: %{non_neg_integer() => object()},
            bindings: %{String.t() => ref()},
            member_assigns: [{target :: String.t(), key :: String.t(), ref()}],
            object_assigns: [{target :: String.t(), [ref()]}],
            imports: %{String.t() => {source :: String.t(), String.t() | :default | :namespace}},
            exports: %{(String.t() | :default) => ref()},
            exports_open: boolean(),
            live_sockets: [Soundcheck.JS.Extractor.LiveSocket.t()],
            pushes: [Soundcheck.JS.Extractor.Push.t()],
            handles: [Soundcheck.JS.Extractor.Handle.t()],
            window_listeners: [Soundcheck.JS.Extractor.WindowListener.t()]
          }
  end

  @doc """
  Extracts facts from `source`.

  Options:

    * `:file` - the file path recorded in spans (default `"nofile"`)
    * `:position` - a function from byte offset to file `{line, column}`,
      for script bodies embedded in another file (default: positions
      within `source`)
  """
  @spec extract(String.t(), keyword()) :: Facts.t()
  def extract(source, opts \\ []) do
    file = Keyword.get(opts, :file, "nofile")
    index = LineIndex.new(source)
    position = Keyword.get(opts, :position, &LineIndex.position(index, &1))

    tokens = Lexer.tokenize(source)

    ctx = %{
      file: file,
      position: position,
      this_aliases: this_aliases(tokens),
      this_fields: this_fields(tokens)
    }

    tokens
    |> scan(nil, %Facts{file: file}, ctx)
    |> in_source_order()
  end

  # The recognizers prepend to the list facts; readers expect source order.
  defp in_source_order(%Facts{} = facts) do
    %{
      facts
      | member_assigns: Enum.reverse(facts.member_assigns),
        object_assigns: Enum.reverse(facts.object_assigns),
        live_sockets: Enum.reverse(facts.live_sockets),
        pushes: Enum.reverse(facts.pushes),
        handles: Enum.reverse(facts.handles),
        window_listeners: Enum.reverse(facts.window_listeners)
    }
  end

  @doc """
  Resolves the hook names registered with `LiveSocket` in this file.

  Returns the registered names with their value refs, and the reasons the
  set may be incomplete: `{:import, source, name}` for a registry that
  comes from another module (the graph resolves those), or `:dynamic` for
  forms the extractor cannot follow. A file without `new LiveSocket`
  returns no names and no reasons.
  """
  @spec registry(Facts.t()) :: names()
  def registry(%Facts{} = facts) do
    Enum.reduce(facts.live_sockets, %Names{}, fn socket, acc ->
      merge(acc, resolve_object_ref(facts, socket.hooks, MapSet.new()))
    end)
  end

  @doc """
  Resolves the keys of the object `ref` points to within this file, following
  bindings, member assignments, `Object.assign`, and spreads. Returns the
  same shape as `registry/1`.
  """
  @spec object_names(Facts.t(), ref()) :: names()
  def object_names(%Facts{} = facts, ref), do: resolve_object_ref(facts, ref, MapSet.new())

  @doc "Returns the pushes and handled events lexically inside the object `id`."
  @spec events_in(Facts.t(), non_neg_integer()) :: hook_events()
  def events_in(%Facts{objects: objects} = facts, id) do
    %Object{range: {from, to}} = Map.fetch!(objects, id)
    inside? = &(&1.offset >= from and &1.offset < to)

    %HookEvents{
      pushes: Enum.filter(facts.pushes, inside?),
      handles: Enum.filter(facts.handles, inside?)
    }
  end

  # ── Resolution ──

  defp resolve_object_ref(_facts, nil, _seen), do: %Names{}

  # LiveSocket options passed as a variable: follow the binding to its object
  # literal and take its `hooks` entry.
  defp resolve_object_ref(facts, {:options, {:ident, name}}, seen) do
    case facts.bindings do
      %{^name => {:object, id}} ->
        resolve_object_ref(facts, hooks_entry(facts.objects[id].entries), seen)

      _other ->
        %Names{open: [:dynamic]}
    end
  end

  defp resolve_object_ref(_facts, {:options, _ref}, _seen), do: %Names{open: [:dynamic]}

  defp resolve_object_ref(facts, {:object, id}, seen) do
    %Object{entries: entries} = Map.fetch!(facts.objects, id)
    Enum.reduce(entries, %Names{}, &merge(&2, entry_names(facts, &1, seen)))
  end

  defp resolve_object_ref(facts, {:ident, name}, seen) do
    cond do
      MapSet.member?(seen, name) ->
        %Names{}

      Map.has_key?(facts.bindings, name) ->
        seen = MapSet.put(seen, name)

        facts
        |> resolve_object_ref(facts.bindings[name], seen)
        |> merge(assigned_names(facts, name, seen))

      Map.has_key?(facts.imports, name) ->
        {source, imported} = facts.imports[name]

        merge(
          %Names{open: [{:import, source, imported}]},
          assigned_names(facts, name, MapSet.put(seen, name))
        )

      true ->
        %Names{open: [:dynamic]}
    end
  end

  defp resolve_object_ref(_facts, :other, _seen), do: %Names{open: [:dynamic]}

  defp entry_names(_facts, {:key, name, ref}, _seen), do: %Names{names: %{name => ref}}
  defp entry_names(facts, {:spread, ref}, seen), do: resolve_object_ref(facts, ref, seen)
  defp entry_names(_facts, {:method, _name}, _seen), do: %Names{}
  defp entry_names(_facts, :computed, _seen), do: %Names{open: [:dynamic]}

  defp assigned_names(facts, name, seen) do
    member =
      for {^name, key, ref} <- facts.member_assigns, reduce: %Names{} do
        acc -> merge(acc, %Names{names: %{key => ref}})
      end

    for {^name, refs} <- facts.object_assigns, ref <- refs, reduce: member do
      acc -> merge(acc, resolve_object_ref(facts, ref, seen))
    end
  end

  @doc """
  Resolves the names `import * as X` binds from this file: every named
  export. Export forms the extractor cannot enumerate (`export * from`,
  destructuring) leave the set open.
  """
  @spec namespace_names(Facts.t()) :: names()
  def namespace_names(%Facts{} = facts) do
    names = for {name, ref} <- facts.exports, is_binary(name), into: %{}, do: {name, ref}
    %Names{names: names, open: if(facts.exports_open, do: [:dynamic], else: [])}
  end

  defp merge(%Names{} = a, %Names{} = b),
    do: %Names{names: Map.merge(a.names, b.names), open: Enum.uniq(a.open ++ b.open)}

  # ── Recognition ──
  #
  # `scan/4` tries the recognizers at every token, so a form nested inside
  # another (a binding inside a hook method) is found too. Each recognizer
  # takes the tokens from the current one to the end of the file and returns
  # updated facts when they start the form it handles, or `nil` to let the
  # next one try. `prev` is the token before the current one.

  @open_brackets ["(", "[", "{"]
  @close_brackets [")", "]", "}"]
  @declarators ["const", "let", "var"]
  @hook_calls ["pushEvent", "pushEventTo", "handleEvent"]

  # How many tokens after `import` may precede `from "source"`.
  @import_clause_limit 65

  defp scan([], _prev, facts, _ctx), do: facts

  defp scan([token | rest] = tokens, prev, facts, ctx) do
    facts =
      declaration(tokens, prev, facts, ctx) || module_syntax(tokens, facts, ctx) ||
        live_socket_call(tokens, facts, ctx) || event_call(tokens, facts, ctx) || facts

    scan(rest, token, facts, ctx)
  end

  defp declaration(
         [{:ident, kw, _, _}, {:ident, name, _, _}, {:punct, "=", _, _} | value],
         _prev,
         facts,
         ctx
       )
       when kw in @declarators do
    %{facts | bindings: Map.put(facts.bindings, name, value_ref(value))}
    |> register_objects(value, ctx)
  end

  defp declaration(
         [{:ident, target, _, _}, {:punct, ".", _, _}, {:ident, key, _, _}, {:punct, "=", _, _}] ++
           value,
         prev,
         facts,
         ctx
       ) do
    if not dot?(prev), do: member_assign(facts, ctx, target, key, value)
  end

  defp declaration(
         [
           {:ident, target, _, _},
           {:punct, "[", _, _},
           {:string, key, _, _},
           {:punct, "]", _, _},
           {:punct, "=", _, _} | value
         ],
         prev,
         facts,
         ctx
       ) do
    if not dot?(prev), do: member_assign(facts, ctx, target, key, value)
  end

  defp declaration(
         [
           {:ident, "Object", _, _},
           {:punct, ".", _, _},
           {:ident, "assign", _, _} | [{:punct, "(", _, _} | _] = call
         ],
         _prev,
         facts,
         ctx
       ), do: object_assign(facts, ctx, call)

  defp declaration(_tokens, _prev, _facts, _ctx), do: nil

  defp module_syntax([{:ident, "import", _, _} | rest], facts, _ctx), do: import_decl(facts, rest)

  defp module_syntax([{:ident, "export", _, _} | rest], facts, ctx),
    do: export_decl(facts, rest, ctx)

  defp module_syntax(_tokens, _facts, _ctx), do: nil

  defp live_socket_call(
         [{:ident, "new", _, _}, {:ident, _, _, _} | _] = [_new | rest],
         facts,
         ctx
       ) do
    with {:ok, call, start} <- live_socket_constructor(rest),
         do: live_socket(facts, ctx, call, start)
  end

  defp live_socket_call(
         [
           {:ident, "window", _, _},
           {:punct, ".", _, _},
           {:ident, "addEventListener", _, _},
           {:punct, "(", _, _},
           {kind, "phx:" <> event, start, stop} | _
         ],
         facts,
         ctx
       )
       when kind in [:string, :template] do
    listener = %WindowListener{event: event, span: span(ctx, start, stop)}
    %{facts | window_listeners: [listener | facts.window_listeners]}
  end

  defp live_socket_call(_tokens, _facts, _ctx), do: nil

  # `LiveSocket(` or a qualified `A.B.LiveSocket(` after `new`: returns the
  # tokens from the opening paren on and the start offset of `LiveSocket`.
  defp live_socket_constructor([
         {:ident, "LiveSocket", start, _} | [{:punct, "(", _, _} | _] = call
       ]), do: {:ok, call, start}

  defp live_socket_constructor([{:ident, _, _, _}, {:punct, ".", _, _} | rest]),
    do: live_socket_constructor(rest)

  defp live_socket_constructor(_tokens), do: nil

  defp event_call(
         [
           {:ident, receiver, _, _},
           {:punct, ".", _, _},
           {:ident, name, start, _} | [{:punct, "(", _, _} | _] = call
         ],
         facts,
         ctx
       )
       when name in @hook_calls do
    if this?(ctx, receiver), do: hook_call(facts, ctx, name, call, start)
  end

  defp event_call(
         [
           {:ident, receiver, _, _},
           {:punct, ".", _, _},
           {:ident, field, _, _},
           {:punct, ".", _, _},
           {:ident, name, start, _} | [{:punct, "(", _, _} | _] = call
         ],
         facts,
         ctx
       )
       when name in @hook_calls do
    if this?(ctx, receiver) and field in ctx.this_fields,
      do: hook_call(facts, ctx, name, call, start)
  end

  defp event_call(_tokens, _facts, _ctx), do: nil

  defp member_assign(facts, ctx, target, key, value) do
    %{facts | member_assigns: [{target, key, value_ref(value)} | facts.member_assigns]}
    |> register_objects(value, ctx)
  end

  # `call` starts at the opening paren of `Object.assign(target, ...sources)`.
  defp object_assign(facts, ctx, call) do
    case arguments(call) do
      {[[{:ident, target, _, _}] | sources], _last} ->
        refs = Enum.map(sources, &value_ref/1)
        facts = %{facts | object_assigns: [{target, refs} | facts.object_assigns]}
        Enum.reduce(sources, facts, &register_objects(&2, &1, ctx))

      _other ->
        facts
    end
  end

  # `call` starts at the opening paren of `LiveSocket(url, Socket, opts)`.
  defp live_socket(facts, ctx, call, start) do
    {args, last} = arguments(call)
    span = span(ctx, start, token_stop(last))

    case args do
      [_url, _socket, opts | _] ->
        socket = %LiveSocket{hooks: hooks_option(opts), span: span}
        register_objects(%{facts | live_sockets: [socket | facts.live_sockets]}, opts, ctx)

      _fewer ->
        socket = %LiveSocket{hooks: nil, span: span}
        %{facts | live_sockets: [socket | facts.live_sockets]}
    end
  end

  # The `hooks` value inside the options object literal, or
  # `{:options, ref}` when the options are a variable the registry resolves.
  defp hooks_option(opts) do
    case value_ref(opts) do
      {:object, _id} ->
        {items, _close} = arguments(opts)
        items |> entries() |> Enum.map(&elem(&1, 0)) |> hooks_entry()

      other ->
        {:options, other}
    end
  end

  defp hooks_entry(entries) do
    Enum.find_value(entries, fn
      {:key, "hooks", ref} -> ref
      _entry -> nil
    end)
  end

  # `call` starts at the opening paren of the hook call.
  defp hook_call(facts, ctx, name, call, start) do
    {args, last} = arguments(call)
    {first, second} = first_two(args)
    span = span(ctx, start, token_stop(last))

    case name do
      "pushEvent" ->
        push = %Push{
          kind: :push_event,
          event: event_arg(first),
          target: :view,
          offset: start,
          span: span
        }

        %{facts | pushes: [push | facts.pushes]}

      "pushEventTo" ->
        push = %Push{
          kind: :push_event_to,
          event: event_arg(second),
          target: target_arg(ctx, first),
          offset: start,
          span: span
        }

        %{facts | pushes: [push | facts.pushes]}

      "handleEvent" ->
        handle = %Handle{event: event_arg(first), offset: start, span: span}
        %{facts | handles: [handle | facts.handles]}
    end
  end

  defp first_two([first, second | _rest]), do: {first, second}
  defp first_two([first]), do: {first, nil}
  defp first_two([]), do: {nil, nil}

  defp event_arg([{:string, value, _, _}]), do: {:literal, value}
  defp event_arg([{:template, value, _, _}]) when is_binary(value), do: {:literal, value}
  defp event_arg(_arg), do: :dynamic

  defp target_arg(_ctx, [{:string, selector, _, _}]), do: {:selector, selector}

  defp target_arg(ctx, [{:ident, receiver, _, _}, {:punct, ".", _, _}, {:ident, "el", _, _}]),
    do: if(this?(ctx, receiver), do: :self_el, else: :dynamic)

  defp target_arg(_ctx, _arg), do: :dynamic

  # import X from "s" | import {a, b as c} from "s" | import X, {a} from "s"
  # | import * as X from "s"
  defp import_decl(facts, tokens) do
    case import_clause_and_source(tokens, @import_clause_limit, []) do
      {:ok, clause, source} ->
        imports =
          for {local, imported} <- import_clause(clause, []),
              into: facts.imports,
              do: {local, {source, imported}}

        %{facts | imports: imports}

      :error ->
        facts
    end
  end

  # Splits the tokens after `import` at `from "source"`. Gives up at a `;`
  # or after `limit` tokens, so a dynamic `import(...)` call does not pick
  # up the `from` of a later statement.
  defp import_clause_and_source(
         [{:ident, "from", _, _}, {:string, source, _, _} | _],
         _limit,
         clause
       ), do: {:ok, Enum.reverse(clause), source}

  defp import_clause_and_source([{:punct, ";", _, _}, _next | _], _limit, _clause), do: :error

  defp import_clause_and_source([token, next | rest], limit, clause) when limit > 1,
    do: import_clause_and_source([next | rest], limit - 1, [token | clause])

  defp import_clause_and_source(_tokens, _limit, _clause), do: :error

  defp import_clause([], acc), do: acc

  defp import_clause(
         [{:punct, "*", _, _}, {:ident, "as", _, _}, {:ident, local, _, _} | rest],
         acc
       ), do: import_clause(rest, [{local, :namespace} | acc])

  defp import_clause([{:punct, "{", _, _} | rest], acc), do: named_imports(rest, acc)
  defp import_clause([{:ident, "type", _, _} | rest], acc), do: import_clause(rest, acc)

  defp import_clause([{:ident, local, _, _} | rest], acc),
    do: import_clause(rest, [{local, :default} | acc])

  defp import_clause([_token | rest], acc), do: import_clause(rest, acc)

  defp named_imports([{:punct, "}", _, _} | rest], acc), do: import_clause(rest, acc)

  defp named_imports(
         [{:ident, name, _, _}, {:ident, "as", _, _}, {:ident, local, _, _} | rest],
         acc
       ), do: named_imports(rest, [{local, name} | acc])

  defp named_imports([{:ident, name, _, _} | rest], acc),
    do: named_imports(rest, [{name, name} | acc])

  defp named_imports([_token | rest], acc), do: named_imports(rest, acc)
  defp named_imports([], acc), do: acc

  # export default <value> | export const X = <value> | export {a, b as c}
  # | export [async] function X | export class X, which record `X` with an
  # opaque value. `export *` and destructuring exports name bindings the
  # extractor cannot enumerate, so they mark the exports open.
  defp export_decl(facts, [{:ident, "default", _, _} | value], ctx) do
    %{facts | exports: Map.put(facts.exports, :default, value_ref(value))}
    |> register_objects(value, ctx)
  end

  defp export_decl(
         facts,
         [{:ident, kw, _, _}, {:ident, name, _, _}, {:punct, "=", _, _} | _],
         _ctx
       )
       when kw in @declarators,
       do: %{facts | exports: Map.put(facts.exports, name, {:ident, name})}

  defp export_decl(facts, [{:punct, "{", _, _} | _] = tokens, _ctx) do
    names =
      case enclosed(tokens) do
        {:ok, inner, _close, _rest} -> named_imports(inner, [])
        :error -> []
      end

    exports = for {local, name} <- names, into: facts.exports, do: {local, {:ident, name}}
    %{facts | exports: exports}
  end

  defp export_decl(facts, [{:ident, kw, _, _}, {:ident, name, _, _} | _], _ctx)
       when kw in ["function", "class"],
       do: %{facts | exports: Map.put(facts.exports, name, :other)}

  defp export_decl(
         facts,
         [{:ident, "async", _, _}, {:ident, "function", _, _}, {:ident, name, _, _} | _],
         _ctx
       ), do: %{facts | exports: Map.put(facts.exports, name, :other)}

  defp export_decl(facts, [{:punct, "*", _, _} | _], _ctx), do: %{facts | exports_open: true}

  defp export_decl(facts, [{:ident, kw, _, _}, {:punct, bracket, _, _} | _], _ctx)
       when kw in @declarators and bracket in ["{", "["], do: %{facts | exports_open: true}

  defp export_decl(facts, _tokens, _ctx), do: facts

  # ── Objects ──

  # The ref for the value that starts `tokens`: an object literal, or an
  # identifier that is the whole value.
  defp value_ref([{:punct, "{", start, _} | _]), do: {:object, start}

  defp value_ref([{:ident, name, _, _} | rest]),
    do: if(simple_end?(rest), do: {:ident, name}, else: :other)

  defp value_ref(_tokens), do: :other

  defp simple_end?([{:punct, p, _, _} | _]), do: p in [",", ";", ")", "}", "]"]
  defp simple_end?(_tokens), do: true

  # Records the object literal that starts `tokens`, and every object
  # literal nested as a value inside it, in `facts.objects`. An unclosed
  # literal has no entries and spans its opening brace.
  defp register_objects(facts, [{:punct, "{", start, _} | _] = tokens, ctx) do
    {items, close} = arguments(tokens)
    entries = entries(items)
    stop = token_stop(close)

    object = %Object{
      entries: Enum.map(entries, &elem(&1, 0)),
      range: {start, stop},
      span: span(ctx, start, stop)
    }

    facts = %{facts | objects: Map.put(facts.objects, start, object)}

    Enum.reduce(entries, facts, fn {_entry, value}, facts ->
      register_objects(facts, value, ctx)
    end)
  end

  defp register_objects(facts, _tokens, _ctx), do: facts

  # Each entry among the comma-separated `items` of an object literal,
  # with the tokens of its value: `[]` when the entry has no value the
  # extractor follows.
  defp entries(items), do: for([_ | _] = item <- items, do: entry(item))

  defp entry([{:punct, "...", _, _} | value]), do: {{:spread, value_ref(value)}, value}
  defp entry([{:punct, "[", _, _} | _]), do: {:computed, []}

  defp entry([{kind, name, _, _}, {:punct, ":", _, _} | value]) when kind in [:ident, :string],
    do: {{:key, name, value_ref(value)}, value}

  defp entry([{:ident, name, _, _}]), do: {{:key, name, {:ident, name}}, []}

  defp entry([{:ident, modifier, _, _}, {:ident, name, _, _}, {:punct, "(", _, _} | _])
       when modifier in ["async", "get", "set"], do: {{:method, name}, []}

  defp entry([{:ident, name, _, _}, {:punct, "(", _, _} | _]), do: {{:method, name}, []}
  defp entry(_tokens), do: {:computed, []}

  # ── Brackets ──
  #
  # A closing bracket pairs with the innermost open one of its kind; a
  # closer that does not match the innermost open bracket is an ordinary
  # token.

  # The comma-separated items between the bracket that starts `tokens` and
  # its match, each a token list, and the closing bracket. An unclosed
  # bracket has no items and stands in for its own closer.
  defp arguments([open | _] = tokens) do
    case enclosed(tokens) do
      {:ok, inner, close, _rest} -> {split_commas(inner, [], []), close}
      :error -> {[], open}
    end
  end

  # The tokens between the bracket that starts `tokens` and its match, the
  # match, and the tokens after it.
  defp enclosed([{:punct, open, _, _} | rest]) when open in @open_brackets,
    do: enclosed(rest, [open], [])

  defp enclosed([], _stack, _inner), do: :error

  defp enclosed([{:punct, open, _, _} = token | rest], stack, inner) when open in @open_brackets,
    do: enclosed(rest, [open | stack], [token | inner])

  defp enclosed([{:punct, close, _, _} = token | rest], [open | outer] = stack, inner)
       when close in @close_brackets do
    cond do
      not pair?(open, close) -> enclosed(rest, stack, [token | inner])
      outer == [] -> {:ok, Enum.reverse(inner), token, rest}
      true -> enclosed(rest, outer, [token | inner])
    end
  end

  defp enclosed([token | rest], stack, inner), do: enclosed(rest, stack, [token | inner])

  defp pair?("(", ")"), do: true
  defp pair?("[", "]"), do: true
  defp pair?("{", "}"), do: true
  defp pair?(_open, _close), do: false

  # Splits `tokens` at the commas outside any bracket. An item between two
  # commas may be empty; a trailing comma adds none.
  defp split_commas([], [], items), do: Enum.reverse(items)
  defp split_commas([], item, items), do: Enum.reverse([Enum.reverse(item) | items])

  defp split_commas([{:punct, ",", _, _} | rest], item, items),
    do: split_commas(rest, [], [Enum.reverse(item) | items])

  defp split_commas([{:punct, open, _, _} = token | rest] = tokens, item, items)
       when open in @open_brackets do
    case enclosed(tokens) do
      {:ok, inner, close, rest} ->
        split_commas(rest, [close | Enum.reverse(inner, [token | item])], items)

      :error ->
        split_commas(rest, [token | item], items)
    end
  end

  defp split_commas([token | rest], item, items), do: split_commas(rest, [token | item], items)

  # ── Token helpers ──

  # Names bound to `this` anywhere in the file (`const self = this`).
  defp this_aliases(tokens) do
    for [{:ident, kw, _, _}, {:ident, name, _, _}, {:punct, "=", _, _}, {:ident, "this", _, _}] <-
          Enum.chunk_every(tokens, 4, 1, :discard),
        kw in @declarators,
        do: name
  end

  defp this?(ctx, receiver), do: receiver == "this" or receiver in ctx.this_aliases

  # Fields the file assigns on `this` (`this.hook = hook`).
  defp this_fields(tokens) do
    for [{:ident, "this", _, _}, {:punct, ".", _, _}, {:ident, field, _, _}, {:punct, "=", _, _}] <-
          Enum.chunk_every(tokens, 4, 1, :discard),
        into: MapSet.new(),
        do: field
  end

  defp dot?(token), do: match?({:punct, ".", _, _}, token)

  defp token_stop({_type, _value, _start, stop}), do: stop

  defp span(ctx, start, stop), do: Span.new(ctx.file, ctx.position.(start), ctx.position.(stop))
end
