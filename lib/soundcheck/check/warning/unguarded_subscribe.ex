defmodule Soundcheck.Check.Warning.UnguardedSubscribe do
  use Soundcheck.Check,
    id: "SC501",
    base_priority: :normal,
    category: :warning,
    confidence: :high,
    tier: :syntactic,
    default: true,
    summary: "PubSub subscriptions in `mount/3` outside `connected?(socket)`",
    param_defaults: [subscribe_functions: [~r/^Phoenix\.PubSub\.subscribe$/, ~r/\.subscribe$/]],
    explanations: [
      check: """
      Flags PubSub subscriptions in a LiveView's `mount/3` that are not
      guarded by `connected?(socket)`. `mount/3` also runs for the
      disconnected HTTP render, in a short-lived process that subscribes,
      renders once, and exits; only the connected mount needs the
      subscription.

      Before:

          def mount(_params, _session, socket) do
            Phoenix.PubSub.subscribe(MyApp.PubSub, "posts")
            {:ok, socket}
          end

      After:

          def mount(_params, _session, socket) do
            if connected?(socket), do: Phoenix.PubSub.subscribe(MyApp.PubSub, "posts")
            {:ok, socket}
          end

      A call counts as a subscription when its alias-expanded name
      (`Phoenix.PubSub.subscribe`, `MyApp.Endpoint.subscribe`) matches
      `subscribe_functions`. Calls inside `if connected?(socket)` (or
      `unless !connected?(socket)`) are guarded, and so are calls behind a
      compound condition that is false when disconnected, such as
      `if connected?(socket) and enabled?()`. `connected?(socket) or ...`
      guards nothing. Subscriptions in helpers that `mount/3` calls are not
      followed.
      """,
      params: [
        subscribe_functions:
          "Regexes or exact names of subscribing functions, as `Module.function`."
      ]
    ]

  alias Soundcheck.Analysis.Calls
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph
  alias Soundcheck.NameFilter
  alias Soundcheck.Span

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, params) do
    for %{kind: :live_view} = entry <- graph.modules,
        clause <- Map.get(entry.functions, {:mount, 3}, []),
        %{qualified: qualified} = call <-
          Calls.remote(clause.body, entry.aliases, guard: :connected),
        qualified != nil,
        NameFilter.matches_any?(qualified, Keyword.fetch!(params, :subscribe_functions)) do
      {line, column} = call.start
      span = Span.new(entry.file, {line, column}, {line, column + String.length(call.written)})

      Diagnostic.new(
        __MODULE__,
        span,
        "`#{call.written}` in `mount/3` is not guarded by `connected?(socket)`, so the disconnected " <>
          "render's short-lived process subscribes too."
      )
    end
  end
end
