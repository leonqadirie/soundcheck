defmodule Soundcheck.Check.Warning.SubscribedWithoutHandleInfo do
  use Soundcheck.Check,
    id: "SC601",
    base_priority: :high,
    category: :warning,
    confidence: :high,
    tier: :semantic,
    default: true,
    summary: "LiveViews that subscribe in `mount/3` but define no `handle_info/2`",
    param_defaults: [subscribe_functions: [~r/^Phoenix\.PubSub\.subscribe$/, ~r/\.subscribe$/]],
    explanations: [
      check: """
      Flags LiveViews that subscribe to PubSub in `mount/3` but define no
      `handle_info/2` at all. The first broadcast on the topic crashes the
      LiveView.

      Before:

          def mount(_params, _session, socket) do
            if connected?(socket), do: Phoenix.PubSub.subscribe(MyApp.PubSub, "posts")
            {:ok, socket}
          end

      After:

          def handle_info({:post_created, post}, socket),
            do: {:noreply, stream_insert(socket, :posts, post)}

      Subscriptions match `subscribe_functions` by alias-expanded name, as
      in `UnguardedSubscribe`. A `handle_info/2` injected by a `use` macro
      counts, because the check reads the compiled module; a handler
      attached with `attach_hook/4` silences it.
      """,
      params: [
        subscribe_functions:
          "Regexes or exact names of subscribing functions, as `Module.function`."
      ]
    ]

  alias Soundcheck.Analysis.Handlers
  alias Soundcheck.Analysis.LiveModules
  alias Soundcheck.Analysis.MountHooks
  alias Soundcheck.Diagnostic
  alias Soundcheck.Elixir.ModuleIndex
  alias Soundcheck.Graph
  alias Soundcheck.NameFilter
  alias Soundcheck.Span

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, params) do
    routes = MountHooks.routes(graph)

    for {entry, :view} <- LiveModules.all(graph),
        {:ok, %{patterns: [], closed?: true}} <-
          [Handlers.handler_set(entry.name, :handle_info, routes)],
        clause <- Map.get(entry.functions, {:mount, 3}, []),
        {name, meta, written} <- remote_calls(clause.body, entry),
        NameFilter.matches_any?(name, Keyword.fetch!(params, :subscribe_functions)) do
      {line, column} = {meta[:line], meta[:column]}
      span = Span.new(entry.file, {line, column}, {line, column + String.length(written)})

      Diagnostic.new(
        __MODULE__,
        span,
        "`#{inspect(entry.name)}` subscribes with `#{written}` but defines no `handle_info/2`; " <>
          "the first broadcast crashes it."
      )
    end
  end

  # `{qualified_name, meta, written}` for every remote call; the meta points
  # at the module alias, where the written call starts.
  defp remote_calls(body, entry) do
    for {{:., _, [{:__aliases__, alias_meta, _} = module_ast, fun]}, _meta, args} <-
          Macro.prewalker(body),
        is_atom(fun) and is_list(args),
        module <- [ModuleIndex.expand(module_ast, entry.aliases)],
        is_atom(module),
        do: {"#{inspect(module)}.#{fun}", alias_meta, "#{Macro.to_string(module_ast)}.#{fun}"}
  end
end
