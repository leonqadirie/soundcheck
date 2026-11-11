defmodule Soundcheck.UnverifiableReasonsTest do
  # One finding per unverifiable reason the check tests do not already
  # produce, so every reason reaches `Soundcheck.Diagnostic.new/4`, which
  # rejects reasons outside `t:Soundcheck.Diagnostic.reason/0`. The last
  # test fails when a reason joins the type without a test.
  use Soundcheck.CheckCase

  alias Soundcheck.Check.Warning.PossiblyUnsetAssign
  alias Soundcheck.Check.Warning.UndefinedHook
  alias Soundcheck.Check.Warning.UnhandledAsyncResult
  alias Soundcheck.Check.Warning.UnhandledEvent
  alias Soundcheck.Check.Warning.UnhandledHookEvent
  alias Soundcheck.Graph
  alias Soundcheck.Span

  @fixture "test/support/fixtures/unverifiable.ex"
  @js [js_paths: ["test/support/fixtures/assets/js"]]
  @npm_js [js_paths: ["test/support/fixtures/assets/npm_hooks_js"]]

  # Never compiled, so `Soundcheck.Beam.Introspect` cannot load it.
  @uncompiled ~S'''
  defmodule MyAppWeb.UncompiledLive do
    use Phoenix.LiveView

    def render(assigns) do
      ~H"""
      <button phx-click="go">x</button>
      <button phx-click="go" phx-target={@target}>y</button>
      """
    end
  end
  '''

  @chart_component ~S'''
  defmodule MyAppWeb.ChartComponents do
    use Phoenix.Component

    def chart(assigns), do: ~H'<div id="chart" phx-hook="Chart"></div>'
  end
  '''

  # Reasons whose own check tests already produce and assert them.
  @covered_elsewhere [
    # unhandled_event_test.exs
    :dynamic_event,
    :guarded,
    :css_selector,
    :no_render_path,
    # messages_test.exs
    :attach_hook,
    # undefined_hook_test.exs, unhandled_server_push_event_test.exs
    :no_live_socket
  ]

  @covered_here [
    :dynamic_target,
    :not_loadable,
    :myself_outside_component,
    :unreadable_receiver,
    :open_handlers,
    :self_el_in_function_component,
    :open_hook_registry,
    :hook_module_unreadable,
    :unreadable_on_mount,
    :open_handle_params
  ]

  defp fixture, do: [{@fixture, File.read!(@fixture)}]

  defp reasons(diagnostics), do: for(%{resolution: {:unverifiable, r}} <- diagnostics, do: r)

  # The reasons `check` reports inside the fixture module named `module`.
  defp reasons_for(check, sources, module) do
    graph = Graph.build(inputs(sources), js_paths: [])
    span = Graph.module(graph, module).span

    for %{resolution: {:unverifiable, reason}} = diagnostic <- analyze(check, sources),
        Span.contains?(span, diagnostic.primary.start),
        do: reason
  end

  describe "event routing (UnhandledEvent)" do
    test ":dynamic_target for a phx-target expression" do
      assert :dynamic_target in reasons(analyze(UnhandledEvent, @uncompiled))
    end

    test ":not_loadable when the rendering module cannot be loaded" do
      assert :not_loadable in reasons(analyze(UnhandledEvent, @uncompiled))
    end

    test ":myself_outside_component for @myself in a LiveView" do
      assert [:myself_outside_component] =
               reasons_for(UnhandledEvent, fixture(), SoundcheckFixtures.MyselfInViewLive)
    end

    test ":unreadable_receiver when the receiver has no debug info" do
      assert [:unreadable_receiver] =
               reasons_for(UnhandledEvent, fixture(), SoundcheckFixtures.UndebuggableLive)
    end

    test ":open_handlers when the receiver attaches handle_event hooks" do
      assert [:open_handlers] =
               reasons_for(UnhandledEvent, fixture(), SoundcheckFixtures.AttachHookLive)
    end
  end

  describe "hooks" do
    test ":self_el_in_function_component for pushEventTo(this.el) from a function component" do
      assert [:self_el_in_function_component] =
               reasons(analyze(UnhandledHookEvent, @chart_component, [], @js))
    end

    test ":open_hook_registry when LiveSocket registers hooks from an npm package" do
      source = ~S'''
      defmodule MyAppWeb.FeedLive do
        use Phoenix.LiveView
        def render(assigns), do: ~H'<div id="feed" phx-hook="Feed"></div>'
      end
      '''

      assert [:open_hook_registry] = reasons(analyze(UndefinedHook, source, [], @npm_js))
    end
  end

  describe "on_mount hooks without debug info" do
    test ":hook_module_unreadable for a handler set the hook may extend" do
      assert [:hook_module_unreadable] =
               reasons_for(
                 UnhandledAsyncResult,
                 fixture(),
                 SoundcheckFixtures.UnreadableHookAsyncLive
               )
    end

    test ":unreadable_on_mount for assigns the hook may set" do
      assert [:unreadable_on_mount] =
               reasons_for(
                 PossiblyUnsetAssign,
                 fixture(),
                 SoundcheckFixtures.UnreadableHookAssignsLive
               )
    end
  end

  test ":open_handle_params when handle_params/3 passes the socket to a helper" do
    assert [:open_handle_params] =
             reasons_for(PossiblyUnsetAssign, fixture(), SoundcheckFixtures.OpenParamsLive)
  end

  test "every reason in the type has a test" do
    {:ok, types} = Code.Typespec.fetch_types(Soundcheck.Diagnostic)
    {:type, {:reason, ast, []}} = Enum.find(types, &match?({:type, {:reason, _, _}}, &1))

    assert Enum.sort(atoms(ast)) == Enum.sort(@covered_elsewhere ++ @covered_here)
  end

  defp atoms({:type, _, :union, members}), do: Enum.flat_map(members, &atoms/1)
  defp atoms({:atom, _, atom}), do: [atom]
end
