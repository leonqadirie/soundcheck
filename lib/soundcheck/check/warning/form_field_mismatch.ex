defmodule Soundcheck.Check.Warning.FormFieldMismatch do
  use Soundcheck.Check,
    id: "SC105",
    base_priority: :normal,
    category: :warning,
    confidence: :medium,
    tier: :syntactic,
    default: false,
    summary: "`handle_event/3` patterns that require a form field the form never sends",
    explanations: [
      check: """
      Flags `handle_event/3` clauses whose params pattern requires a form
      field the form never sends. The clause cannot match the form's
      params, so submitting raises `FunctionClauseError` or falls through
      to another clause.

      Before:

          <.form for={@form} phx-submit="save">
            <.input field={@form[:email]} />
          </.form>

          def handle_event("save", %{"user" => %{"email" => email, "name" => name}}, socket)

      After:

          <.form for={@form} phx-submit="save">
            <.input field={@form[:email]} />
            <.input field={@form[:name]} />
          </.form>

      The form's name comes from `to_form(data, as: name)` or from the
      schema struct in the changeset (`%MyApp.Accounts.User{}` sends
      `user[...]`). Its fields are the keys it reads as `@form[:key]` (or
      through `:let`) and literal `name="user[key]"` attributes. The check
      stays silent when it cannot resolve the form's name, or when the
      form is passed whole to a component that could add fields. Keys
      starting with `_` are ignored.
      """
    ]

  alias Soundcheck.Analysis.AssignUse
  alias Soundcheck.Analysis.Handlers
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph
  alias Soundcheck.Heex.Node
  alias Soundcheck.Heex.Reads
  alias Soundcheck.Heex.Walker
  alias Soundcheck.Span

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, _params) do
    for %{kind: kind, name: module} = entry <- graph.modules,
        kind in [:live_view, :live_component],
        forms = forms(graph, entry),
        forms != [],
        clause <- Map.get(entry.functions, {:handle_event, 3}, []),
        [event, pattern, _socket] = clause.args,
        is_binary(event),
        emitting = Enum.filter(forms, &(event in &1.events)),
        emitting != [],
        {name, required} <- required(pattern),
        {:ok, fields} <- [known_fields(emitting, name)],
        key <- required,
        key not in fields do
      span = Span.new(entry.file, {clause.line, clause.column}, {clause.line, clause.column + 3})

      Diagnostic.new(
        __MODULE__,
        span,
        "This `handle_event(#{inspect(event)}, ...)` clause in `#{inspect(module)}` requires " <>
          "`#{name}[#{key}]`, but no form sending #{inspect(event)} has that field, so the " <>
          "clause never matches its params."
      )
    end
  end

  # The fields the forms named `name` send, when there is such a form and
  # all of them are complete.
  defp known_fields(forms, name) do
    Enum.reduce(forms, :none, fn
      %{name: ^name, complete?: false}, _acc -> :error
      %{name: ^name, fields: fields}, :none -> {:ok, fields}
      %{name: ^name, fields: fields}, {:ok, acc} -> {:ok, MapSet.union(acc, fields)}
      _form, acc -> acc
    end)
  end

  # ── Handler patterns ──

  # `{form_name, required_keys}` for each `%{"name" => %{"key" => _}}` in the
  # params pattern.
  defp required(pattern) do
    for {name, inner} <- Handlers.map_pattern_pairs(pattern),
        is_binary(name),
        pairs = Handlers.map_pattern_pairs(inner),
        keys = for({key, _value} <- pairs, is_binary(key), not underscored?(key), do: key),
        keys != [],
        do: {name, keys}
  end

  defp underscored?(key), do: String.starts_with?(key, "_")

  # ── Forms in templates ──

  # Every form in the module's templates that sends events to the module
  # itself, with its resolved name, its fields, and whether those fields
  # are all known.
  defp forms(graph, %{name: module, kind: kind} = entry) do
    names = form_names(entry)

    for template <- graph.templates,
        match?({^module, _fun}, template.owner),
        %Node.Element{} = element <- Walker.elements(template.root),
        {:ok, form_ref, name} <- [form(element, names)],
        targets_self?(element, kind),
        events = events(element),
        events != [] do
      {fields, complete?} = fields(element, form_ref, name)
      %{name: name, events: events, fields: fields, complete?: complete?}
    end
  end

  # A LiveView's own form sends to it unless it names a target; a
  # LiveComponent's form sends to it with `phx-target={@myself}`.
  defp targets_self?(element, :live_view), do: attribute(element, "phx-target") == nil

  defp targets_self?(element, :live_component),
    do: match?({:expr, {:@, _, [{:myself, _, _}]}, _, _}, attribute(element, "phx-target"))

  defp events(element) do
    for name <- ["phx-submit", "phx-change"],
        {:string, event, _delimiter, _span} <- [attribute(element, name)],
        do: event
  end

  # The form element: `for={@key}`, where the module assigns `@key` a form
  # or changeset whose name resolves. `as=` on the element overrides it.
  defp form(element, names) do
    with {:expr, {:@, _, [{key, _, _}]}, _, _} <- attribute(element, "for"),
         {:ok, name} <- element_name(element, Map.get(names, key)) do
      {:ok, let_var(element) || {:@, key}, name}
    else
      _other -> :error
    end
  end

  defp element_name(element, resolved) do
    case attribute(element, "as") do
      {:expr, as, _, _} when is_atom(as) and not is_nil(as) -> {:ok, Atom.to_string(as)}
      {:string, as, _, _} -> {:ok, as}
      nil when is_binary(resolved) -> {:ok, resolved}
      _other -> :error
    end
  end

  defp let_var(element) do
    case attribute(element, ":let") do
      {:expr, {var, _, context}, _, _} when is_atom(var) and is_atom(context) -> {:var, var}
      _other -> nil
    end
  end

  defp attribute(%Node.Element{attrs: attrs}, name) do
    Enum.find_value(attrs, fn
      %Node.Attr{name: ^name, value: value} -> value
      _attr -> nil
    end)
  end

  # Fields the form's children read as `form[:key]`, plus literal
  # `name="form[key]"` attributes. A form passed whole anywhere could gain
  # fields there: the fields are then incomplete.
  defp fields(element, form_ref, name) do
    {keys, complete?} =
      element.children
      |> Reads.node_expressions()
      |> Enum.reduce({[], true}, fn ast, {keys, complete?} ->
        {_ast, {keys, complete?}} =
          Macro.prewalk(ast, {keys, complete?}, &field_read(&1, &2, form_ref))

        {keys, complete?}
      end)

    literal =
      for %Node.Element{attrs: attrs} <- Walker.elements(element.children),
          %Node.Attr{name: "name", value: {:string, input_name, _, _}} <- attrs,
          [_, ^name, key] <- [Regex.run(~r/^(\w+)\[(\w+)\]/, input_name)],
          do: key

    {MapSet.new(keys ++ literal), complete?}
  end

  defp field_read({{:., _, [Access, :get]}, _, [ref, key]} = node, {keys, complete?}, form_ref)
       when is_atom(key) or is_binary(key) do
    if ref?(ref, form_ref),
      do: {:ok, {[to_string(key) | keys], complete?}},
      else: {node, {keys, complete?}}
  end

  defp field_read(node, {keys, complete?}, form_ref) do
    if ref?(node, form_ref), do: {node, {keys, false}}, else: {node, {keys, complete?}}
  end

  defp ref?({:@, _, [{key, _, _}]}, {:@, key}), do: true
  defp ref?({var, _, context}, {:var, var}) when is_atom(context), do: true
  defp ref?(_node, _form_ref), do: false

  # ── Form names from writes ──

  # The form name each assign key resolves to, when every write to it
  # resolves to the same name.
  defp form_names(entry) do
    entry
    |> AssignUse.writes()
    |> Enum.group_by(& &1.key, &resolve(&1.value))
    |> Enum.flat_map(fn {key, names} ->
      case Enum.uniq(names) do
        [name] when is_binary(name) -> [{key, name}]
        _ambiguous -> []
      end
    end)
    |> Map.new()
  end

  defp resolve({:|>, _, [data, {:to_form, _, args}]}), do: resolve_to_form([data | args])
  defp resolve({:to_form, _, args}) when is_list(args), do: resolve_to_form(args)

  defp resolve({{:., _, [_module, :to_form]}, _, args}) when is_list(args),
    do: resolve_to_form(args)

  defp resolve(_value), do: nil

  defp resolve_to_form([data | rest]) do
    case Enum.find_value(rest, &(Keyword.keyword?(&1) && Keyword.get(&1, :as))) do
      as when is_atom(as) and not is_nil(as) -> Atom.to_string(as)
      as when is_binary(as) -> as
      nil -> schema_name(data)
      _dynamic -> nil
    end
  end

  # The resource name of the only schema struct literal in a changeset
  # expression, as Phoenix names Ecto forms.
  defp schema_name(data) do
    structs =
      for {:%, _, [{:__aliases__, _, segments}, _fields]} <- Macro.prewalker(data), do: segments

    case Enum.uniq(structs) do
      [segments] -> segments |> List.last() |> Atom.to_string() |> Macro.underscore()
      _none_or_many -> nil
    end
  end
end
