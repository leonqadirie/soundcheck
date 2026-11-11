defmodule Soundcheck.Check.Refactor.ExpensiveMountWork do
  use Soundcheck.Check,
    id: "SC502",
    base_priority: :normal,
    category: :refactor,
    confidence: :medium,
    tier: :syntactic,
    default: false,
    summary: "Database and HTTP calls in `mount/3` that run for both mounts",
    param_defaults: [
      expensive_modules: [~r/\.Repo$/, ~r/^(Req|Finch|HTTPoison|Tesla)$/]
    ],
    explanations: [
      check: """
      Flags database and HTTP calls in a LiveView's `mount/3` outside a
      `connected?(socket)` branch. `mount/3` runs twice per page load, once
      for the disconnected HTTP render and once when the socket connects, so
      the query or request runs twice.

      Before:

          def mount(_params, _session, socket) do
            {:ok, assign(socket, :posts, Repo.all(Post))}
          end

      After:

          def mount(_params, _session, socket) do
            {:ok, assign_async(socket, :posts, fn -> {:ok, %{posts: Repo.all(Post)}} end)}
          end

      Calls inside closures (`assign_async/3`, `start_async/3`) and inside
      `if connected?(socket)` do not count. Modules match
      `expensive_modules` (atoms or regexes on the alias-expanded name).
      Pages that must render the data on the first, disconnected response
      (for search engines) load it in both mounts on purpose; leave this
      check off for them.
      """,
      params: [
        expensive_modules: "Modules whose calls count as expensive: atoms or regexes."
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
        %{module: module} = call <- Calls.remote(clause.body, entry.aliases, guard: :connected),
        module != nil,
        NameFilter.matches_any?(module, Keyword.fetch!(params, :expensive_modules)) do
      {line, column} = call.start
      span = Span.new(entry.file, {line, column}, {line, column + String.length(call.written)})

      Diagnostic.new(
        __MODULE__,
        span,
        "`#{call.written}` in `mount/3` runs for both the disconnected and the connected mount; " <>
          "load it with `assign_async/3` or inside `if connected?(socket)`."
      )
    end
  end
end
