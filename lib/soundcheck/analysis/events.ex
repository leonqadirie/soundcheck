defmodule Soundcheck.Analysis.Events do
  @moduledoc false
  # Event emitters in templates and the modules that receive them.
  #
  # An emitter is a `phx-*` event attribute (`phx-click`, `phx-submit`, ...)
  # or a `JS.push/1,2,3` call inside one. Its event is a literal string or
  # `:dynamic`; its target is `:none`, `:myself`, `{:assign, key}` for any
  # other `@key`, a `{:selector, s}`, or `:dynamic`, from the element's
  # `phx-target` or the push's `:target` option.
  #
  # Inside a function component, `@myself` and `@key` name the component's
  # own attr. Its call sites decide the target: `myself={@myself}` from a
  # LiveComponent's render targets that LiveComponent, and
  # `target={@target}` from another function component forwards again.
  #
  # Receivers follow LiveView's rules along every render path from the
  # emitter's template up to a root:
  #
  #   * no target: the LiveView whose render contains the element. An event
  #     inside a LiveComponent still goes to the parent LiveView, and an event
  #     inside a function component goes to every LiveView that renders it.
  #   * `@myself`: the LiveComponent whose own render contains the element.
  #
  # Anything else is unverifiable, with a reason: a selector target, a
  # dynamic event or target, a template with no known render path, or an
  # owner module that cannot be loaded.

  alias Soundcheck.Analysis.Components
  alias Soundcheck.Analysis.Guards
  alias Soundcheck.Analysis.Handlers
  alias Soundcheck.Beam.Introspect
  alias Soundcheck.Diagnostic
  alias Soundcheck.Heex.KeywordAttrs
  alias Soundcheck.Heex.Node
  alias Soundcheck.Heex.Template
  alias Soundcheck.Heex.Walker
  alias Soundcheck.Span

  @event_attrs ~w(phx-click phx-click-away phx-submit phx-change phx-blur phx-focus
                  phx-keydown phx-keyup phx-window-blur phx-window-focus
                  phx-window-keydown phx-window-keyup phx-viewport-top phx-viewport-bottom)

  @type target ::
          :none | :myself | {:assign, atom()} | :self_el | {:selector, String.t()} | :dynamic

  # How many function components deep `phx-target={@myself}` is followed.
  @target_depth 4

  defmodule Emitter do
    @moduledoc false
    # One event emitter: an event attribute or a `JS.push` call. `value` is
    # the AST of a push's `:value` option, or `nil`.
    @enforce_keys [:event, :target, :via, :span]
    defstruct [:event, :target, :via, :span, :value]

    @type t :: %__MODULE__{
            event: {:literal, String.t()} | {:forward, atom()} | :dynamic,
            target: Soundcheck.Analysis.Events.target() | nil,
            via: String.t(),
            span: Soundcheck.Span.t(),
            value: Macro.t() | nil
          }
  end

  @type emitter :: Emitter.t()

  @type receivers :: Diagnostic.resolved([module()])

  @doc """
  Returns the event emitters in `template`: its elements' in source order,
  then those of keyword attributes (`link(..., phx_click: "x")`, see
  `Soundcheck.Heex.KeywordAttrs`). Events named `lv:...` are LiveView's
  own (`lv:clear-flash`) and never appear.
  """
  @spec emitters(Template.t(), MapSet.t({atom(), arity()})) :: [emitter()]
  def emitters(%Template{root: root}, js_helpers \\ MapSet.new()) do
    (Walker.elements(root) ++ KeywordAttrs.elements(root))
    |> Enum.flat_map(&element_emitters(&1, js_helpers))
    |> Enum.reject(&match?(%Emitter{event: {:literal, "lv:" <> _}}, &1))
  end

  @doc """
  Returns the `{name, arity}` of every project function that builds `JS`
  commands without `JS.push`, such as a `toggle/2` helper around
  `JS.toggle/2`. A template expression calling one emits no server event.
  Arities include those that default arguments allow.
  """
  @spec js_helpers(Soundcheck.Graph.t()) :: MapSet.t({atom(), arity()})
  def js_helpers(%Soundcheck.Graph{modules: modules}) do
    for entry <- modules,
        {{name, arity}, clauses} <- entry.functions,
        Enum.all?(clauses, &push_free_js?(&1.body)),
        callable <- callable_arities(clauses, arity),
        into: MapSet.new(),
        do: {name, callable}
  end

  defp push_free_js?(body),
    do: js_command?(body, MapSet.new()) and js_pushes(body, "nofile") == []

  defp callable_arities([%{args: args} | _], arity) do
    defaults = Enum.count(args, &match?({:\\, _, [_, _]}, &1))
    (arity - defaults)..arity
  end

  @doc """
  Resolves the modules that receive `emitter` from `template`, given the
  index from `Soundcheck.Analysis.Components.render_index/1`. A call
  site whose attrs rule out an `:if` guard around the emitter
  (`Soundcheck.Analysis.Guards`) renders no route to it.
  """
  @spec receivers(Template.t(), emitter(), Components.Index.t()) :: receivers()
  def receivers(%Template{} = template, emitter, index) do
    with {:ok, reach} <- receiver_reach(template, emitter, index),
         do: {:ok, reach |> Map.keys() |> Enum.sort()}
  end

  @doc """
  Like `receivers/3`, but maps each receiving module to whether every
  render path from `emitter` to it crosses a condition (`:if`, or an EEx
  `if`, `unless`, `case`, or `cond`) that no call site on the path proves.
  The emitter may never render for a guarded receiver.
  """
  @spec receiver_reach(Template.t(), emitter(), Components.Index.t()) ::
          Diagnostic.resolved(%{module() => boolean()})
  def receiver_reach(
        %Template{} = template,
        %{event: {:literal, _event}, target: target} = emitter,
        index
      ) do
    case target do
      :none -> root_reach(template, emitter.span, index, MapSet.new(), false)
      :myself -> unguarded(target_component(template, :myself, index, @target_depth))
      {:assign, key} -> unguarded(target_component(template, key, index, @target_depth))
      :self_el -> unguarded(own_root(template))
      {:selector, _selector} -> {:unverifiable, :css_selector}
      :dynamic -> {:unverifiable, :dynamic_target}
    end
  end

  def receiver_reach(_template, %{event: _not_literal}, _index),
    do: {:unverifiable, :dynamic_event}

  defp unguarded({:ok, modules}), do: {:ok, Map.new(modules, &{&1, false})}
  defp unguarded(unverifiable), do: unverifiable

  @doc """
  Rewrites an emitter whose event a function component takes from an attr
  (`phx-click={@event}`) into one emitter per call site: a literal at the
  call site (`<.icon_button event="save">`) becomes an emitter there, routed
  from the calling template; a nested `@attr` forwards again, up to three
  levels; a `JS.push` at the call site contributes its literal events.

  Returns one entry per resolved call site, `{:ok, template, emitter}`, or
  `{:unverifiable, reason}` for paths that do not resolve. Emitters with a
  literal or dynamic event come back unchanged.
  """
  @spec expand(Template.t(), emitter(), Components.Index.t()) ::
          [{:ok, Template.t(), emitter()} | Diagnostic.unverifiable()]
  def expand(template, emitter, call_sites), do: expand(template, emitter, call_sites, 3)

  defp expand(template, %Emitter{event: {:forward, key}} = emitter, call_sites, depth) do
    case {forward_callee(template), emitter.target, depth} do
      {_callee, _target, 0} -> [{:unverifiable, :dynamic_event}]
      {nil, _target, _depth} -> [{:unverifiable, :dynamic_event}]
      {_callee, target, _depth} when target != :none -> [{:unverifiable, :dynamic_target}]
      {callee, :none, depth} -> forward_sites(callee, key, emitter.via, call_sites, depth)
    end
  end

  defp expand(template, emitter, _call_sites, _depth), do: [{:ok, template, emitter}]

  # The function component that owns the template, or `nil` when the owner
  # is a LiveView or LiveComponent render, where `@key` is a socket assign.
  defp forward_callee(%Template{owner: {module, :render}}) do
    case Introspect.live(module) do
      {:ok, _live} -> nil
      {:error, _reason} -> {:function, module, :render}
    end
  end

  defp forward_callee(%Template{owner: {module, fun}}), do: {:function, module, fun}

  defp forward_callee(_template), do: nil

  # A delegation hands over the caller's assigns, where the attr is a
  # socket assign soundcheck cannot read.
  defp forward_sites(callee, key, via, call_sites, depth) do
    case Map.get(call_sites.sites, callee, []) do
      [] ->
        if Map.has_key?(call_sites.delegators, callee),
          do: [{:unverifiable, :dynamic_event}],
          else: [{:unverifiable, :no_render_path}]

      sites ->
        name = Atom.to_string(key)

        for {caller, element} <- sites,
            %Node.Attr{name: ^name, value: value} <- element.attrs,
            result <- forwarded_value(caller, value, via, call_sites, depth) do
          result
        end
    end
  end

  defp forwarded_value(caller, {:string, event, _delimiter, span}, via, _call_sites, _depth),
    do: [{:ok, caller, %Emitter{event: {:literal, event}, target: :none, via: via, span: span}}]

  defp forwarded_value(caller, {:expr, ast, _source, span}, via, call_sites, depth) do
    case {expr_event(ast), js_pushes(ast, span.file)} do
      {{:forward, key}, _pushes} ->
        expand(
          caller,
          %Emitter{event: {:forward, key}, target: :none, via: via, span: span},
          call_sites,
          depth - 1
        )

      {_dynamic, []} ->
        [{:unverifiable, :dynamic_event}]

      {_dynamic, pushes} ->
        for push <- pushes, do: {:ok, caller, %{push | target: push.target || :none}}
    end
  end

  defp forwarded_value(_caller, nil, _via, _call_sites, _depth), do: []

  # ── Emitters ──

  @doc """
  Returns the event emitters of one element, in attribute order, given
  the push-free JS helpers from `js_helpers/1`.
  """
  @spec element_emitters(Node.Element.t(), MapSet.t({atom(), arity()})) :: [emitter()]
  def element_emitters(%Node.Element{attrs: attrs}, js_helpers) do
    target = attrs |> Enum.find(&(&1.name == "phx-target")) |> element_target()

    for %Node.Attr{name: name} = attr <- attrs,
        name in @event_attrs,
        emitter <- attr_emitters(attr, target, js_helpers) do
      emitter
    end
  end

  defp attr_emitters(
         %Node.Attr{name: name, value: {:string, event, _delimiter, span}},
         target,
         _helpers
       ), do: [%Emitter{event: {:literal, event}, target: target, via: name, span: span}]

  defp attr_emitters(
         %Node.Attr{name: name, value: {:expr, {:error, _reason}, _source, span}},
         target,
         _helpers
       ), do: [%Emitter{event: :dynamic, target: target, via: name, span: span}]

  # A `JS` command chain emits server events only through `JS.push`; a chain
  # without one (`JS.toggle(...)`) emits none. Any other expression is a
  # dynamic event name.
  defp attr_emitters(%Node.Attr{name: name, value: {:expr, ast, _source, span}}, target, helpers) do
    case {js_pushes(ast, span.file), js_command?(ast, helpers)} do
      {[], true} ->
        []

      {[], false} ->
        [%Emitter{event: expr_event(ast), target: target, via: name, span: span}]

      {pushes, _js?} ->
        Enum.map(pushes, &Map.update!(&1, :target, fn push_target -> push_target || target end))
    end
  end

  defp attr_emitters(%Node.Attr{}, _target, _helpers), do: []

  # `phx-click={@event}` in a function component forwards the caller's attr;
  # `expand/3` resolves it per call site.
  defp expr_event({:@, _, [{key, _, context}]}) when is_atom(key) and is_atom(context),
    do: {:forward, key}

  defp expr_event(_ast), do: :dynamic

  defp element_target(nil), do: :none

  defp element_target(%Node.Attr{value: {:string, selector, _delimiter, _span}}),
    do: {:selector, selector}

  defp element_target(%Node.Attr{value: {:expr, ast, _source, _span}}), do: expr_target(ast)
  defp element_target(%Node.Attr{}), do: :dynamic

  defp expr_target({:@, _, [{:myself, _, context}]}) when is_atom(context), do: :myself

  defp expr_target({:@, _, [{key, _, context}]}) when is_atom(key) and is_atom(context),
    do: {:assign, key}

  defp expr_target(selector) when is_binary(selector), do: {:selector, selector}
  defp expr_target(_ast), do: :dynamic

  # `JS.push("event")`, `JS.push(js, "event")`, and `|> JS.push("event")`,
  # with an optional `target:` option. A push whose event is not a literal
  # string is dynamic.
  defp js_pushes(ast, file) do
    for {{:., _, [{:__aliases__, meta, alias}, :push]}, _meta, args} <- Macro.prewalker(ast),
        alias in [[:JS], [:Phoenix, :LiveView, :JS]],
        do: push(args, meta, Enum.join(alias ++ [:push], "."), file)
  end

  # True when `ast` calls a `JS` command or a push-free JS helper.
  defp js_command?(ast, helpers) do
    ast
    |> Macro.prewalker()
    |> Enum.any?(fn
      {{:., _, [{:__aliases__, _, alias}, _command]}, _meta, _args}
      when alias in [[:JS], [:Phoenix, :LiveView, :JS]] ->
        true

      {name, _meta, args} when is_atom(name) and is_list(args) ->
        MapSet.member?(helpers, {name, length(args)})

      _node ->
        false
    end)
  end

  # The span covers the qualified call name, from the alias's position.
  defp push(args, meta, call, file) do
    {event, opts} =
      case args do
        [event | rest] when is_binary(event) -> {{:literal, event}, List.first(rest)}
        [_js, event | rest] when is_binary(event) -> {{:literal, event}, List.first(rest)}
        _dynamic -> {:dynamic, nil}
      end

    line = meta[:line]
    column = meta[:column]
    span = Span.new(file, {line, column}, {line, column + String.length(call)})

    %Emitter{
      event: event,
      target: push_target(opts),
      via: "JS.push",
      span: span,
      value: push_value(opts)
    }
  end

  defp push_target(opts) when is_list(opts) do
    case Keyword.fetch(opts, :target) do
      {:ok, target} -> expr_target(target)
      :error -> nil
    end
  end

  defp push_target(_opts), do: nil

  defp push_value(opts) when is_list(opts), do: Keyword.get(opts, :value)
  defp push_value(_opts), do: nil

  # ── Receivers ──

  # The LiveComponents that receive `phx-target={@key}` from `template`. In
  # a LiveView or LiveComponent render, only `@myself` resolves; in a
  # function component, `@key` is an attr its call sites set, or the
  # caller's own assign when a function hands it its assigns whole.
  defp target_component(%Template{owner: {_module, _fun} = owner}, key, index, depth),
    do: target_owner(owner, key, index, depth, MapSet.new())

  defp target_component(_template, _key, _index, _depth), do: {:unverifiable, :dynamic_target}

  defp target_owner({module, fun}, key, index, depth, seen) do
    case {Introspect.live(module), fun, key} do
      {{:ok, %{kind: :component}}, :render, :myself} ->
        {:ok, [module]}

      {{:ok, %{kind: :view}}, :render, :myself} ->
        {:unverifiable, :myself_outside_component}

      {{:ok, _live}, :render, _key} ->
        {:unverifiable, :dynamic_target}

      {{:error, :not_loadable}, _fun, :myself} ->
        {:unverifiable, :not_loadable}

      {{:error, :not_loadable}, _fun, _key} ->
        {:unverifiable, :dynamic_target}

      {_function_component, fun, key} ->
        forwarded_target({:function, module, fun}, key, index, depth, seen)
    end
  end

  # Every call site must pass the attr on as `{@myself}` or another `{@key}`
  # that resolves. A function already on the path (a recursive component)
  # adds no receivers.
  defp forwarded_target(_callee, _key, _index, 0, _seen), do: {:unverifiable, :dynamic_target}

  defp forwarded_target(callee, key, index, depth, seen) do
    sites = Map.get(index.sites, callee, [])
    delegators = Map.get(index.delegators, callee, [])
    seen? = MapSet.member?(seen, {callee, key})
    seen = MapSet.put(seen, {callee, key})

    cond do
      seen? ->
        {:ok, []}

      sites == [] and delegators == [] ->
        {:unverifiable, :no_render_path}

      true ->
        name = Atom.to_string(key)

        site_targets =
          for {caller, element} <- sites do
            attr = Enum.find(element.attrs, &(&1.name == name))
            site_target(caller, attr, index, depth - 1, seen)
          end

        delegated = for owner <- delegators, do: target_owner(owner, key, index, depth - 1, seen)
        union_modules(site_targets ++ delegated)
    end
  end

  defp site_target(
         %Template{owner: {_module, _fun} = owner},
         %Node.Attr{value: {:expr, ast, _source, _span}},
         index,
         depth,
         seen
       ) do
    case expr_target(ast) do
      :myself -> target_owner(owner, :myself, index, depth, seen)
      {:assign, key} -> target_owner(owner, key, index, depth, seen)
      _other -> {:unverifiable, :dynamic_target}
    end
  end

  defp site_target(_caller, _attr, _index, _depth, _seen), do: {:unverifiable, :dynamic_target}

  defp union_modules(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, modules}, {:ok, acc} -> {:cont, {:ok, modules ++ acc}}
      unverifiable, _acc -> {:halt, unverifiable}
    end)
    |> case do
      {:ok, modules} -> {:ok, modules |> Enum.uniq() |> Enum.sort()}
      unverifiable -> unverifiable
    end
  end

  # `pushEventTo(this.el, ...)` from a hook goes to the LiveComponent or
  # LiveView whose own render contains the hook's element.
  defp own_root(%Template{owner: {module, :render}}) do
    case Introspect.live(module) do
      {:ok, _live} -> {:ok, [module]}
      {:error, _reason} -> {:unverifiable, :not_loadable}
    end
  end

  defp own_root(_template), do: {:unverifiable, :self_el_in_function_component}

  @doc """
  Checks `event` against each receiver's `handle_event/3` clauses. Returns
  `:handled`, `{:missing, [{module, handler_set}]}` when every receiver
  that lacks the event has a closed handler set, or `{:unverifiable,
  reason}` otherwise. `routes` are the project's live routes, passed to
  `Handlers.handler_set/3`.
  """
  @spec check_handled([module()], String.t(), [Introspect.route()]) ::
          :handled | {:missing, [{module(), Handlers.handler_set()}]} | Diagnostic.unverifiable()
  def check_handled(receivers, event, routes) do
    results =
      for module <- receivers, do: {module, Handlers.handler_set(module, :handle_event, routes)}

    missing =
      for {module, {:ok, set}} <- results,
          not Handlers.handles?(set, {:literal, event}),
          do: {module, set}

    cond do
      Enum.any?(results, &match?({_module, {:error, _reason}}, &1)) ->
        {:unverifiable, :unreadable_receiver}

      missing == [] ->
        :handled

      Enum.any?(missing, fn {_module, set} -> not set.closed? end) ->
        {:unverifiable, :open_handlers}

      true ->
        {:missing, missing}
    end
  end

  # The views that render `span` in `template`, hopping from each component
  # to the call sites and delegations that can render it. Maps each view to
  # whether every path to it crosses a condition nothing on the path proves
  # (`guarded?`).
  defp root_reach(%Template{owner: nil}, _span, _index, _seen, _guarded?),
    do: {:unverifiable, :no_render_path}

  defp root_reach(%Template{owner: owner} = template, span, index, seen, guarded?),
    do: owner_reach(owner, {template, span}, index, seen, guarded?)

  # `location` is the template position inside `owner` that must render, or
  # `nil` for a hop that enters `owner` whole (a delegation, or a
  # LiveComponent's parents).
  defp owner_reach({module, fun} = owner, location, index, seen, guarded?) do
    if MapSet.member?(seen, owner) do
      {:ok, %{}}
    else
      seen = MapSet.put(seen, owner)

      case {Introspect.live(module), fun} do
        {{:ok, %{kind: :view}}, :render} ->
          {:ok, %{module => guarded? or conditions(location) != []}}

        {{:ok, %{kind: :component}}, :render} ->
          via_sites({:live_component, module}, location, index, seen, guarded?)

        {{:error, :not_loadable}, _fun} ->
          {:unverifiable, :not_loadable}

        {_live_or_not, fun} ->
          via_sites({:function, module, fun}, location, index, seen, guarded?)
      end
    end
  end

  defp conditions({template, span}), do: Guards.conditions(template.root, span)
  defp conditions(nil), do: []

  # A callee whose every call site rules out the guards around `location`,
  # and that no function delegates to, renders nowhere, so nothing receives
  # from it. A hop that does not prove every condition around `location`
  # makes the rest of its path guarded; a delegation passes no attrs, so it
  # proves none.
  defp via_sites(callee, location, index, seen, guarded?) do
    guards = if location, do: Guards.at(elem(location, 0).root, elem(location, 1)), else: []
    conditions = conditions(location)
    sites = Map.get(index.sites, callee, [])
    delegators = Map.get(index.delegators, callee, [])

    if sites == [] and delegators == [] do
      {:unverifiable, :no_render_path}
    else
      site_hops =
        for {_template, element} = site <- sites,
            not Guards.excluded?(guards, element, callee),
            do: {site, guarded? or not Guards.holds?(conditions, element, callee)}

      delegation_hops =
        for owner <- delegators, do: {{:owner, owner}, guarded? or conditions != []}

      union_reach(site_hops ++ delegation_hops, index, seen)
    end
  end

  # Every hop's path must resolve; the first unverifiable one decides. A
  # view reached on any unguarded path is unguarded.
  defp union_reach(hops, index, seen) do
    Enum.reduce_while(hops, {:ok, %{}}, fn {hop, guarded?}, {:ok, acc} ->
      case hop_reach(hop, index, seen, guarded?) do
        {:ok, reach} -> {:cont, {:ok, Map.merge(acc, reach, fn _view, a, b -> a and b end)}}
        unverifiable -> {:halt, unverifiable}
      end
    end)
  end

  defp hop_reach({:owner, owner}, index, seen, guarded?),
    do: owner_reach(owner, nil, index, seen, guarded?)

  defp hop_reach({template, element}, index, seen, guarded?),
    do: root_reach(template, element.span, index, seen, guarded?)
end
