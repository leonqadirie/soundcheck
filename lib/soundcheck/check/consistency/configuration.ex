defmodule Soundcheck.Check.Consistency.Configuration do
  use Soundcheck.Check,
    id: "SC000",
    base_priority: :normal,
    category: :consistency,
    confidence: :high,
    tier: :semantic,
    default: true,
    summary: "LiveView not loaded, LiveView modules that cannot load or carry no debug info",
    explanations: [
      check: """
      Reports why soundcheck's semantic checks could not analyze part of
      the project, so a clean run never hides a misconfiguration:

        * Phoenix LiveView is not loaded in the VM running Credo, so every
          semantic check is a no-op;
        * a LiveView or LiveComponent module could not be loaded, usually
          because the project was not compiled;
        * a LiveView or LiveComponent was compiled without debug info, so
          checks cannot read its handlers.

      Semantic checks skip such modules silently and leave the reporting
      here, once per module. Run `mix compile` before `mix credo`, for
      example with a Mix alias:

          lint: ["compile", "credo --strict"]
      """
    ]

  alias Soundcheck.Beam.DebugInfo
  alias Soundcheck.Beam.Introspect
  alias Soundcheck.Diagnostic
  alias Soundcheck.Elixir.ModuleIndex.Entry
  alias Soundcheck.Graph
  alias Soundcheck.Span

  @live_kinds [:live_view, :live_component]

  @impl Soundcheck.Rule
  def analyze(%Graph{modules: modules}, _params) do
    live = Enum.filter(modules, &(&1.kind in @live_kinds and &1.name != nil))

    cond do
      live == [] ->
        []

      not Introspect.live_view_available?() ->
        [first | _] = live

        [
          diagnostic(
            first,
            "Phoenix LiveView is not loaded in the VM running Credo, so soundcheck's semantic " <>
              "checks did not run. Run `mix compile` before `mix credo`."
          )
        ]

      true ->
        Enum.flat_map(live, &module_problems/1)
    end
  end

  defp module_problems(%Entry{name: name} = entry) do
    case {Introspect.live(name), DebugInfo.definitions(name)} do
      {{:error, :not_loadable}, _debug_info} ->
        [
          diagnostic(
            entry,
            "Could not load `#{inspect(name)}`, so soundcheck's semantic checks skipped it. " <>
              "Run `mix compile` before `mix credo`."
          )
        ]

      {{:ok, _live}, {:error, :no_debug_info}} ->
        [
          diagnostic(
            entry,
            "`#{inspect(name)}` was compiled without debug info, so soundcheck cannot read its " <>
              "handlers. Remove `debug_info: false` from its compile options."
          )
        ]

      _fine ->
        []
    end
  end

  defp diagnostic(%Entry{file: file, span: %Span{start: {line, column}}}, message) do
    span = Span.new(file, {line, column}, {line, column + String.length("defmodule")})

    Diagnostic.new(__MODULE__, span, message)
  end
end
