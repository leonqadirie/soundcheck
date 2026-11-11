defmodule Soundcheck.Check.Warning.LiveRouteWithoutAuthHook do
  use Soundcheck.Check,
    id: "SC402",
    base_priority: :high,
    category: :warning,
    confidence: :high,
    tier: :semantic,
    default: false,
    summary:
      "Live routes whose live_session and LiveView run no authentication `on_mount` hook that can halt the mount",
    param_defaults: [auth_hooks: :auto, public_paths: []],
    explanations: [
      check: """
      Flags live routes that run no authentication `on_mount` hook. Plugs
      in the router pipeline guard only the first HTTP request; a client
      navigating over an open socket reaches the LiveView without them, so
      each live_session needs its own `on_mount` check.

      Before:

          live_session :admin do
            live "/admin", AdminLive
          end

      After:

          live_session :admin, on_mount: [{MyAppWeb.UserAuth, :require_authenticated}] do
            live "/admin", AdminLive
          end

      A hook counts when its module matches `auth_hooks` (atoms or regexes),
      whether it comes from the route's live_session or the LiveView's own
      `on_mount`, and when its compiled `on_mount/4` clause for the hook's
      argument can stop the mount: return `{:halt, socket}` or raise. A hook
      that provably always continues, such as phx.gen.auth's
      `:mount_current_scope`, only loads the user and protects nothing. When
      a reported LiveView is also served behind a protecting hook elsewhere,
      the message names that route: its events likely assume a signed-in
      user. With the default `:auto`, modules whose name contains
      `Auth` count, and the check reports only when some route uses one, so
      projects that authenticate another way see no findings. List
      intentionally public routes in `public_paths` (route patterns such as
      `"/posts/:id"`, or regexes). Routes to LiveViews defined outside the
      project's sources, such as LiveDashboard and Oban Web, are skipped:
      their router macros take their own `on_mount` option.
      """,
      params: [
        auth_hooks: "`:auto`, or the hook modules (atoms or regexes) that authenticate.",
        public_paths: "Route paths that need no authentication: binaries or regexes."
      ]
    ]

  alias Soundcheck.Analysis.MountHooks
  alias Soundcheck.Beam.Introspect
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph
  alias Soundcheck.NameFilter
  alias Soundcheck.Span

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, params) do
    own = for %{name: name} <- graph.modules, name != nil, into: MapSet.new(), do: name

    routes =
      for %{kind: :router, name: router} = entry <- graph.modules,
          router != nil,
          {:ok, routes} <- [Introspect.live_routes(router)],
          route <- routes,
          route.live_view in own,
          do: {entry, route, hooks(route)}

    {auth_hooks, applies?} = auth_hooks(Keyword.fetch!(params, :auth_hooks), routes)

    checked =
      for {entry, route, hooks} <- routes do
        named =
          Enum.filter(hooks, fn {module, _arg} -> NameFilter.matches_any?(module, auth_hooks) end)

        {entry, route, named,
         Enum.any?(named, fn {module, arg} -> MountHooks.can_halt?(module, arg) end)}
      end

    protected = for {_entry, route, _named, true} <- checked, do: route

    for {entry, route, named, false} <- checked,
        applies?,
        not NameFilter.matches_any?(route.path, Keyword.fetch!(params, :public_paths)) do
      span = declaration(entry, route.path)

      Diagnostic.new(
        __MODULE__,
        span,
        "Live route `#{route.path}` (`#{inspect(route.live_view)}`, live_session " <>
          "#{inspect(route.live_session)}) #{problem(named)}; add one or list the path in " <>
          "`public_paths`." <> elsewhere(route, protected)
      )
    end
  end

  defp problem([]), do: "runs no authentication `on_mount` hook"

  defp problem(named) do
    hooks =
      Enum.map_join(named, ", ", fn {module, arg} -> "`#{inspect(module)}` #{inspect(arg)}" end)

    "runs only auth hooks that never halt (#{hooks}), so no hook can deny the mount"
  end

  defp elsewhere(route, protected) do
    case Enum.find(protected, &(&1.live_view == route.live_view)) do
      nil ->
        ""

      other ->
        " `#{inspect(route.live_view)}` is also served at `#{other.path}` behind live_session " <>
          "#{inspect(other.live_session)}, so its events likely assume a signed-in user."
    end
  end

  defp hooks(route) do
    module_hooks =
      case Introspect.live(route.live_view) do
        {:ok, %{on_mount: hooks}} -> hooks
        {:error, _reason} -> []
      end

    Enum.uniq(route.on_mount ++ module_hooks)
  end

  # `:auto` applies only when some route already runs an `*Auth*` hook.
  defp auth_hooks(:auto, routes) do
    entries = [~r/Auth/]

    {entries,
     Enum.any?(routes, fn {_entry, _route, hooks} ->
       Enum.any?(hooks, fn {module, _arg} -> NameFilter.matches_any?(module, entries) end)
     end)}
  end

  defp auth_hooks(entries, _routes), do: {entries, true}

  # The `live` declaration in the router source, or the router module when
  # the path comes from a macro or an interpolated string.
  defp declaration(entry, path) do
    case Enum.find(entry.live_routes, &(&1.path == path)) do
      %{line: line, column: column} -> Span.new(entry.file, {line, column}, {line, column + 4})
      nil -> entry.span
    end
  end
end
