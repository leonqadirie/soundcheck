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
    # A `pushEvent` or `pushEventTo` call. `offset` is the token index of the
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
    # A `handleEvent` call. `offset` is the token index of the call.
    @enforce_keys [:event, :offset, :span]
    defstruct [:event, :offset, :span]

    @type t :: %__MODULE__{
            event: Soundcheck.JS.Extractor.event(),
            offset: non_neg_integer(),
            span: Soundcheck.Span.t()
          }
  end

  @type push :: Push.t()
  @type handle :: Handle.t()

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

    @typedoc "An object literal, keyed in `objects` by the token index of its `{`."
    @type object :: %{
            entries: [entry()],
            range: {non_neg_integer(), non_neg_integer()},
            span: Soundcheck.Span.t()
          }

    @type t :: %__MODULE__{
            file: Path.t(),
            objects: %{non_neg_integer() => object()},
            bindings: %{String.t() => ref()},
            member_assigns: [{target :: String.t(), key :: String.t(), ref()}],
            object_assigns: [{target :: String.t(), [ref()]}],
            imports: %{String.t() => {source :: String.t(), String.t() | :default | :namespace}},
            exports: %{(String.t() | :default) => ref()},
            exports_open: boolean(),
            live_sockets: [%{hooks: ref() | nil, span: Soundcheck.Span.t()}],
            pushes: [Soundcheck.JS.Extractor.Push.t()],
            handles: [Soundcheck.JS.Extractor.Handle.t()],
            window_listeners: [%{event: String.t(), span: Soundcheck.Span.t()}]
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

    tokens = source |> Lexer.tokenize() |> List.to_tuple()

    ctx = %{
      tokens: tokens,
      matches: matches(tokens),
      file: file,
      position: position,
      this_aliases: this_aliases(tokens),
      this_fields: this_fields(tokens)
    }

    0..(tuple_size(tokens) - 1)//1
    |> Enum.reduce(%Facts{file: file}, &visit(&2, &1, ctx))
    |> in_source_order()
  end

  # `visit/3` prepends to the list facts; readers expect source order.
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
  @spec registry(Facts.t()) :: %{names: %{String.t() => ref()}, open: [term()]}
  def registry(%Facts{} = facts) do
    Enum.reduce(facts.live_sockets, %{names: %{}, open: []}, fn socket, acc ->
      merge(acc, resolve_object_ref(facts, socket.hooks, MapSet.new()))
    end)
  end

  @doc """
  Resolves the keys of the object `ref` points to within this file, following
  bindings, member assignments, `Object.assign`, and spreads. Returns the
  same shape as `registry/1`.
  """
  @spec object_names(Facts.t(), ref()) :: %{names: %{String.t() => ref()}, open: [term()]}
  def object_names(%Facts{} = facts, ref), do: resolve_object_ref(facts, ref, MapSet.new())

  @doc "Returns the pushes and handled events lexically inside the object `id`."
  @spec events_in(Facts.t(), non_neg_integer()) :: %{pushes: [push()], handles: [handle()]}
  def events_in(%Facts{objects: objects} = facts, id) do
    %{range: {from, to}} = Map.fetch!(objects, id)
    inside? = &(&1.offset >= from and &1.offset < to)
    %{pushes: Enum.filter(facts.pushes, inside?), handles: Enum.filter(facts.handles, inside?)}
  end

  # ── Resolution ──

  defp resolve_object_ref(_facts, nil, _seen), do: %{names: %{}, open: []}

  # LiveSocket options passed as a variable: follow the binding to its object
  # literal and take its `hooks` entry.
  defp resolve_object_ref(facts, {:options, {:ident, name}}, seen) do
    case facts.bindings do
      %{^name => {:object, id}} ->
        resolve_object_ref(facts, hooks_entry(facts.objects[id].entries), seen)

      _other ->
        %{names: %{}, open: [:dynamic]}
    end
  end

  defp resolve_object_ref(_facts, {:options, _ref}, _seen), do: %{names: %{}, open: [:dynamic]}

  defp resolve_object_ref(facts, {:object, id}, seen) do
    %{entries: entries} = Map.fetch!(facts.objects, id)
    Enum.reduce(entries, %{names: %{}, open: []}, &merge(&2, entry_names(facts, &1, seen)))
  end

  defp resolve_object_ref(facts, {:ident, name}, seen) do
    cond do
      MapSet.member?(seen, name) ->
        %{names: %{}, open: []}

      Map.has_key?(facts.bindings, name) ->
        seen = MapSet.put(seen, name)

        facts
        |> resolve_object_ref(facts.bindings[name], seen)
        |> merge(assigned_names(facts, name, seen))

      Map.has_key?(facts.imports, name) ->
        {source, imported} = facts.imports[name]

        merge(
          %{names: %{}, open: [{:import, source, imported}]},
          assigned_names(facts, name, MapSet.put(seen, name))
        )

      true ->
        %{names: %{}, open: [:dynamic]}
    end
  end

  defp resolve_object_ref(_facts, :other, _seen), do: %{names: %{}, open: [:dynamic]}

  defp entry_names(_facts, {:key, name, ref}, _seen), do: %{names: %{name => ref}, open: []}
  defp entry_names(facts, {:spread, ref}, seen), do: resolve_object_ref(facts, ref, seen)
  defp entry_names(_facts, {:method, _name}, _seen), do: %{names: %{}, open: []}
  defp entry_names(_facts, :computed, _seen), do: %{names: %{}, open: [:dynamic]}

  defp assigned_names(facts, name, seen) do
    member =
      for {^name, key, ref} <- facts.member_assigns, reduce: %{names: %{}, open: []} do
        acc -> merge(acc, %{names: %{key => ref}, open: []})
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
  @spec namespace_names(Facts.t()) :: %{names: %{String.t() => ref()}, open: [term()]}
  def namespace_names(%Facts{} = facts) do
    names = for {name, ref} <- facts.exports, is_binary(name), into: %{}, do: {name, ref}
    %{names: names, open: if(facts.exports_open, do: [:dynamic], else: [])}
  end

  defp merge(a, b), do: %{names: Map.merge(a.names, b.names), open: Enum.uniq(a.open ++ b.open)}

  # ── Recognition ──

  # Each recognizer returns updated facts when the tokens at `i` start the
  # form it handles, or `nil` to let the next one try.
  defp visit(facts, i, ctx) do
    tokens = window(ctx, i, 5)

    Enum.find_value(
      [&declaration/4, &module_syntax/4, &live_socket_call/4, &event_call/4],
      facts,
      & &1.(facts, tokens, i, ctx)
    )
  end

  defp declaration(facts, tokens, i, ctx) do
    case tokens do
      [{:ident, kw, _, _}, {:ident, name, _, _}, {:punct, "=", _, _} | _]
      when kw in ["const", "let", "var"] ->
        %{facts | bindings: Map.put(facts.bindings, name, value_ref(ctx, i + 3))}
        |> register_objects(ctx, i + 3)

      [{:ident, target, _, _}, {:punct, ".", _, _}, {:ident, key, _, _}, {:punct, "=", _, _} | _] ->
        if not after_dot?(ctx, i), do: member_assign(facts, ctx, target, key, i + 4)

      [
        {:ident, target, _, _},
        {:punct, "[", _, _},
        {:string, key, _, _},
        {:punct, "]", _, _},
        {:punct, "=", _, _}
      ] ->
        if not after_dot?(ctx, i), do: member_assign(facts, ctx, target, key, i + 5)

      [
        {:ident, "Object", _, _},
        {:punct, ".", _, _},
        {:ident, "assign", _, _},
        {:punct, "(", _, _} | _
      ] ->
        object_assign(facts, ctx, i + 3)

      _other ->
        nil
    end
  end

  defp module_syntax(facts, tokens, i, ctx) do
    case tokens do
      [{:ident, "import", _, _} | _] -> import_decl(facts, ctx, i + 1)
      [{:ident, "export", _, _} | _] -> export_decl(facts, ctx, i + 1)
      _other -> nil
    end
  end

  defp live_socket_call(facts, tokens, i, ctx) do
    case tokens do
      [{:ident, "new", _, _}, {:ident, _, _, _} | _] ->
        with {:ok, open, start} <- live_socket_constructor(ctx, i + 1),
             do: live_socket(facts, ctx, open, start)

      [
        {:ident, "window", _, _},
        {:punct, ".", _, _},
        {:ident, "addEventListener", _, _},
        {:punct, "(", _, _},
        {kind, "phx:" <> event, start, stop}
      ]
      when kind in [:string, :template] ->
        listener = %{event: event, span: span(ctx, start, stop)}
        %{facts | window_listeners: [listener | facts.window_listeners]}

      _other ->
        nil
    end
  end

  # `LiveSocket(` or a qualified `A.B.LiveSocket(` after `new`: returns the
  # index of the opening paren and the start offset of `LiveSocket`.
  defp live_socket_constructor(ctx, at) do
    case {token(ctx, at), token(ctx, at + 1)} do
      {{:ident, "LiveSocket", start, _}, {:punct, "(", _, _}} -> {:ok, at + 1, start}
      {{:ident, _, _, _}, {:punct, ".", _, _}} -> live_socket_constructor(ctx, at + 2)
      _other -> nil
    end
  end

  defp event_call(facts, tokens, i, ctx) do
    case tokens do
      [
        {:ident, receiver, _, _},
        {:punct, ".", _, _},
        {:ident, call, start, _},
        {:punct, "(", _, _} | _
      ]
      when call in ["pushEvent", "pushEventTo", "handleEvent"] ->
        if this?(ctx, receiver), do: hook_call(facts, ctx, call, i + 3, start)

      [
        {:ident, receiver, _, _},
        {:punct, ".", _, _},
        {:ident, field, _, _},
        {:punct, ".", _, _},
        {:ident, call, start, _}
      ]
      when call in ["pushEvent", "pushEventTo", "handleEvent"] ->
        if this_field_call?(ctx, receiver, field, i + 5),
          do: hook_call(facts, ctx, call, i + 5, start)

      _other ->
        nil
    end
  end

  defp member_assign(facts, ctx, target, key, value_at) do
    %{facts | member_assigns: [{target, key, value_ref(ctx, value_at)} | facts.member_assigns]}
    |> register_objects(ctx, value_at)
  end

  defp object_assign(facts, ctx, open) do
    with [{from, to} | rest] when to == from + 1 <- arg_ranges(ctx, open),
         {:ident, target, _, _} <- token(ctx, from) do
      refs = for {start, _to} <- rest, do: value_ref(ctx, start)
      facts = %{facts | object_assigns: [{target, refs} | facts.object_assigns]}
      Enum.reduce(rest, facts, fn {start, _to}, facts -> register_objects(facts, ctx, start) end)
    else
      _other -> facts
    end
  end

  defp live_socket(facts, ctx, open, start) do
    stop = token_stop(ctx, Map.get(ctx.matches, open, open))

    case arg_ranges(ctx, open) do
      [_url, _socket, {from, _to} | _] ->
        socket = %{hooks: hooks_option(ctx, from), span: span(ctx, start, stop)}
        register_objects(%{facts | live_sockets: [socket | facts.live_sockets]}, ctx, from)

      _fewer ->
        socket = %{hooks: nil, span: span(ctx, start, stop)}
        %{facts | live_sockets: [socket | facts.live_sockets]}
    end
  end

  # The `hooks` value inside the options object literal, or
  # `{:options, ref}` when the options are a variable the registry resolves.
  defp hooks_option(ctx, at) do
    case value_ref(ctx, at) do
      {:object, open} -> hooks_entry(object_entries(ctx, open))
      other -> {:options, other}
    end
  end

  defp hooks_entry(entries) do
    Enum.find_value(entries, fn
      {:key, "hooks", ref} -> ref
      _entry -> nil
    end)
  end

  defp hook_call(facts, ctx, call, open, start) do
    stop = token_stop(ctx, Map.get(ctx.matches, open, open))
    {first, second} = first_two(arg_ranges(ctx, open))
    span = span(ctx, start, stop)

    case call do
      "pushEvent" ->
        push = %Push{
          kind: :push_event,
          event: event_arg(ctx, first),
          target: :view,
          offset: start,
          span: span
        }

        %{facts | pushes: [push | facts.pushes]}

      "pushEventTo" ->
        push = %Push{
          kind: :push_event_to,
          event: event_arg(ctx, second),
          target: target_arg(ctx, first),
          offset: start,
          span: span
        }

        %{facts | pushes: [push | facts.pushes]}

      "handleEvent" ->
        handle = %Handle{event: event_arg(ctx, first), offset: start, span: span}
        %{facts | handles: [handle | facts.handles]}
    end
  end

  defp first_two([first, second | _rest]), do: {first, second}
  defp first_two([first]), do: {first, nil}
  defp first_two([]), do: {nil, nil}

  defp event_arg(ctx, {from, to}) when to == from + 1 do
    case token(ctx, from) do
      {:string, value, _, _} -> {:literal, value}
      {:template, value, _, _} when is_binary(value) -> {:literal, value}
      _other -> :dynamic
    end
  end

  defp event_arg(_ctx, _range), do: :dynamic

  defp target_arg(ctx, {from, to}) do
    case for(i <- from..(to - 1)//1, do: token(ctx, i)) do
      [{:string, selector, _, _}] ->
        {:selector, selector}

      [{:ident, receiver, _, _}, {:punct, ".", _, _}, {:ident, "el", _, _}] ->
        if this?(ctx, receiver), do: :self_el, else: :dynamic

      _other ->
        :dynamic
    end
  end

  defp target_arg(_ctx, nil), do: :dynamic

  # import X from "s" | import {a, b as c} from "s" | import X, {a} from "s"
  # | import * as X from "s"
  defp import_decl(facts, ctx, i) do
    case find_from(ctx, i) do
      {:ok, from_at, source} ->
        names = import_names(ctx, i, from_at)

        imports =
          for {local, imported} <- names, into: facts.imports, do: {local, {source, imported}}

        %{facts | imports: imports}

      :error ->
        facts
    end
  end

  defp find_from(ctx, i) do
    Enum.reduce_while(i..min(i + 64, tuple_size(ctx.tokens) - 2)//1, :error, fn j, acc ->
      case {token(ctx, j), token(ctx, j + 1)} do
        {{:ident, "from", _, _}, {:string, source, _, _}} -> {:halt, {:ok, j, source}}
        {{:punct, ";", _, _}, _} -> {:halt, acc}
        _ -> {:cont, acc}
      end
    end)
  end

  defp import_names(ctx, from, to) do
    tokens = for j <- from..(to - 1)//1, do: token(ctx, j)
    import_clause(tokens, [])
  end

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

  # export default <value> | export const X = <value> | export {a, b as c},
  # plus the declaration forms `export_shape/2` reads.
  defp export_decl(facts, ctx, i) do
    case window(ctx, i, 3) do
      [{:ident, "default", _, _} | _] ->
        %{facts | exports: Map.put(facts.exports, :default, value_ref(ctx, i + 1))}
        |> register_objects(ctx, i + 1)

      [{:ident, kw, _, _}, {:ident, name, _, _}, {:punct, "=", _, _}]
      when kw in ["const", "let", "var"] ->
        %{facts | exports: Map.put(facts.exports, name, {:ident, name})}

      [{:punct, "{", _, _} | _] ->
        close = Map.get(ctx.matches, i, i)
        tokens = for j <- (i + 1)..(close - 1)//1, do: token(ctx, j)

        exports =
          for {local, name} <- named_imports(tokens, []),
              into: facts.exports,
              do: {local, {:ident, name}}

        %{facts | exports: exports}

      tokens ->
        export_shape(facts, tokens)
    end
  end

  # export [async] function X | export class X record `X` with an opaque
  # value; `export *` and destructuring exports name bindings the extractor
  # cannot enumerate, so they mark the exports open.
  defp export_shape(facts, tokens) do
    case tokens do
      [{:ident, kw, _, _}, {:ident, name, _, _} | _] when kw in ["function", "class"] ->
        %{facts | exports: Map.put(facts.exports, name, :other)}

      [{:ident, "async", _, _}, {:ident, "function", _, _}, {:ident, name, _, _}] ->
        %{facts | exports: Map.put(facts.exports, name, :other)}

      [{:punct, "*", _, _} | _] ->
        %{facts | exports_open: true}

      [{:ident, kw, _, _}, {:punct, bracket, _, _} | _]
      when kw in ["const", "let", "var"] and bracket in ["{", "["] ->
        %{facts | exports_open: true}

      _other ->
        facts
    end
  end

  # ── Objects ──

  defp value_ref(ctx, at) do
    case {token(ctx, at), token(ctx, at + 1)} do
      {{:punct, "{", _, _}, _} -> {:object, at}
      {{:ident, name, _, _}, next} -> if simple_end?(next), do: {:ident, name}, else: :other
      _other -> :other
    end
  end

  defp simple_end?(nil), do: true
  defp simple_end?({:punct, p, _, _}), do: p in [",", ";", ")", "}", "]"]
  defp simple_end?(_token), do: true

  # Records the object literal at `at`, and every object literal nested as a
  # value inside it, in `facts.objects`.
  defp register_objects(facts, ctx, at) do
    case value_ref(ctx, at) do
      {:object, open} ->
        entries = object_entries(ctx, open)
        close = Map.get(ctx.matches, open, open)
        start = token_start(ctx, open)
        stop = token_stop(ctx, close)

        object = %{entries: entries, range: {start, stop}, span: span(ctx, start, stop)}
        facts = %{facts | objects: Map.put(facts.objects, open, object)}

        Enum.reduce(entries, facts, fn
          {:key, _name, {:object, nested}}, facts -> register_objects(facts, ctx, nested)
          {:spread, {:object, nested}}, facts -> register_objects(facts, ctx, nested)
          _entry, facts -> facts
        end)

      _other ->
        facts
    end
  end

  defp object_entries(ctx, open) do
    for {from, to} <- ranges_between(ctx, open), to > from, do: entry(ctx, from, to)
  end

  defp entry(ctx, from, to) do
    case window(ctx, from, min(3, to - from)) do
      [{:punct, "...", _, _} | _] ->
        {:spread, value_ref(ctx, from + 1)}

      [{:punct, "[", _, _} | _] ->
        :computed

      [{kind, name, _, _}, {:punct, ":", _, _} | _] when kind in [:ident, :string] ->
        {:key, name, value_ref(ctx, from + 2)}

      [{:ident, name, _, _}] when to == from + 1 ->
        {:key, name, {:ident, name}}

      [{:ident, modifier, _, _}, {:ident, name, _, _}, {:punct, "(", _, _}]
      when modifier in ["async", "get", "set"] ->
        {:method, name}

      [{:ident, name, _, _}, {:punct, "(", _, _} | _] ->
        {:method, name}

      _other ->
        :computed
    end
  end

  # ── Calls and argument lists ──

  defp arg_ranges(ctx, open), do: ranges_between(ctx, open)

  # Splits the tokens between the bracket at `open` and its match at depth-0
  # commas, returning `{from, to}` index ranges (`to` exclusive).
  defp ranges_between(ctx, open) do
    case Map.fetch(ctx.matches, open) do
      {:ok, close} -> split_commas(ctx, open + 1, close, open + 1, [])
      :error -> []
    end
  end

  defp split_commas(_ctx, i, close, start, acc) when i >= close do
    acc = if i > start, do: [{start, close} | acc], else: acc
    Enum.reverse(acc)
  end

  defp split_commas(ctx, i, close, start, acc) do
    case token(ctx, i) do
      {:punct, ",", _, _} ->
        split_commas(ctx, i + 1, close, i + 1, [{start, i} | acc])

      {:punct, bracket, _, _} when bracket in ["(", "[", "{"] ->
        split_commas(ctx, Map.get(ctx.matches, i, i) + 1, close, start, acc)

      _token ->
        split_commas(ctx, i + 1, close, start, acc)
    end
  end

  # ── Token helpers ──

  defp matches(tokens) do
    {matches, _stack} =
      Enum.reduce(0..(tuple_size(tokens) - 1)//1, {%{}, []}, fn i, {matches, stack} ->
        case elem(tokens, i) do
          {:punct, open, _, _} when open in ["(", "[", "{"] ->
            {matches, [{open, i} | stack]}

          {:punct, close, _, _} when close in [")", "]", "}"] ->
            close_bracket(matches, stack, close, i)

          _token ->
            {matches, stack}
        end
      end)

    matches
  end

  # Pairs a closing bracket with the innermost open one; an unbalanced
  # closer leaves the stack untouched.
  defp close_bracket(matches, [{open, at} | rest], close, i)
       when {open, close} in [{"(", ")"}, {"[", "]"}, {"{", "}"}],
       do: {Map.put(matches, at, i), rest}

  defp close_bracket(matches, stack, _close, _i), do: {matches, stack}

  # Names bound to `this` anywhere in the file (`const self = this`).
  defp this_aliases(tokens) do
    for [{:ident, kw, _, _}, {:ident, name, _, _}, {:punct, "=", _, _}, {:ident, "this", _, _}] <-
          tokens |> Tuple.to_list() |> Enum.chunk_every(4, 1, :discard),
        kw in ["const", "let", "var"],
        do: name
  end

  defp this?(ctx, receiver), do: receiver == "this" or receiver in ctx.this_aliases

  defp this_field_call?(ctx, receiver, field, open),
    do:
      this?(ctx, receiver) and field in ctx.this_fields and
        match?({:punct, "(", _, _}, token(ctx, open))

  # Fields the file assigns on `this` (`this.hook = hook`).
  defp this_fields(tokens) do
    for [{:ident, "this", _, _}, {:punct, ".", _, _}, {:ident, field, _, _}, {:punct, "=", _, _}] <-
          tokens |> Tuple.to_list() |> Enum.chunk_every(4, 1, :discard),
        into: MapSet.new(),
        do: field
  end

  defp after_dot?(ctx, i), do: i > 0 and match?({:punct, ".", _, _}, token(ctx, i - 1))

  # Up to `n` tokens starting at `i`; fewer near the end of input.
  defp window(ctx, i, n) do
    i..(i + n - 1)//1
    |> Enum.map(&token(ctx, &1))
    |> Enum.reject(&is_nil/1)
  end

  defp token(ctx, i) when i >= 0 and i < tuple_size(ctx.tokens), do: elem(ctx.tokens, i)
  defp token(_ctx, _i), do: nil

  defp token_start(ctx, i), do: ctx |> token(i) |> elem(2)
  defp token_stop(ctx, i), do: ctx |> token(i) |> elem(3)

  defp span(ctx, start, stop), do: Span.new(ctx.file, ctx.position.(start), ctx.position.(stop))
end
