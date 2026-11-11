defmodule Soundcheck.Check.Warning.UnhandledEventTest do
  use Soundcheck.CheckCase

  import Soundcheck.HeexCase, only: [text_at: 2]

  alias Soundcheck.Check.Warning.UnhandledEvent

  @events "test/support/fixtures/events.ex"
  @live "test/support/fixtures/live.ex"

  defp fixtures, do: [{@events, File.read!(@events)}, {@live, File.read!(@live)}]

  defp resolved(diagnostics), do: Enum.filter(diagnostics, &(&1.resolution == :resolved))

  defp unverifiable(diagnostics) do
    for %{resolution: {:unverifiable, reason}} = diagnostic <- diagnostics,
        do: {text_at(File.read!(diagnostic.primary.file), diagnostic.primary), reason}
  end

  setup do
    %{diagnostics: analyze(UnhandledEvent, fixtures())}
  end

  test "fires on events no receiving handler accepts", %{diagnostics: diagnostics} do
    messages = diagnostics |> resolved() |> Enum.map(& &1.message)

    assert messages == [
             "`phx-click=\"incr\"` has no matching `handle_event/3` clause in `SoundcheckFixtures.EventsLive`.",
             "`JS.push=\"missing\"` has no matching `handle_event/3` clause in `SoundcheckFixtures.EventsLive`.",
             "`phx-click=\"forwarded-missing\"` has no matching `handle_event/3` clause in `SoundcheckFixtures.EventsLive`.",
             "`phx-click=\"local-missing\"` has no matching `handle_event/3` clause in `SoundcheckFixtures.EventsLive`.",
             "`phx-click=\"close\"` has no matching `handle_event/3` clause in `SoundcheckFixtures.EventsComponent`.",
             "`phx-click=\"parent-missing\"` has no matching `handle_event/3` clause in `SoundcheckFixtures.EventsLive`."
           ]
  end

  test "spans a JS.push finding over the qualified call name", %{diagnostics: diagnostics} do
    [_incr, push | _] = resolved(diagnostics)
    assert text_at(File.read!(@events), push.primary) == "JS.push"
  end

  test "suggests the closest handled event", %{diagnostics: diagnostics} do
    [incr | _] = resolved(diagnostics)
    assert incr.suggestion == ~S|Did you mean "inc"?|
    assert text_at(File.read!(@events), incr.primary) == "incr"
  end

  test "near misses: handled events, JS.push, function components, and @myself", %{
    diagnostics: diagnostics
  } do
    texts =
      diagnostics |> resolved() |> Enum.map(&text_at(File.read!(&1.primary.file), &1.primary))

    refute "inc" in texts
    refute "save" in texts
    refute "toggle" in texts
  end

  test "marks dynamic, selector, and unrendered emitters unverifiable", %{
    diagnostics: diagnostics
  } do
    assert {"@action", :dynamic_event} in unverifiable(diagnostics)
    assert {"submit", :css_selector} in unverifiable(diagnostics)
    assert {"never-handled", :no_render_path} in unverifiable(diagnostics)
  end

  test "skips JS chains without a push and LiveView's own lv: events", %{diagnostics: diagnostics} do
    refute Enum.any?(diagnostics, &(&1.message =~ "lv:clear-flash"))

    texts = for d <- diagnostics, do: text_at(File.read!(d.primary.file), d.primary)
    refute Enum.any?(texts, &(&1 =~ "JS.toggle"))
    refute Enum.any?(texts, &(&1 =~ ~S|toggle("#menu")|))
  end

  test "resolves events forwarded through component attrs to the call site", %{
    diagnostics: diagnostics
  } do
    [forwarded] = diagnostics |> resolved() |> Enum.filter(&(&1.message =~ "forwarded-missing"))
    assert text_at(File.read!(@events), forwarded.primary) == "forwarded-missing"

    texts =
      diagnostics |> resolved() |> Enum.map(&text_at(File.read!(&1.primary.file), &1.primary))

    refute "inc" in texts
  end

  test "honors ignore_events" do
    diagnostics = analyze(UnhandledEvent, fixtures(), ignore_events: ["incr", ~r/missing/])
    messages = diagnostics |> resolved() |> Enum.map(& &1.message)

    assert [close] = messages
    assert close =~ "close"
  end

  test "skips call sites whose literal attrs or attr defaults rule out the emitter's :if" do
    file = "test/support/fixtures/guarded.ex"
    diagnostics = analyze(UnhandledEvent, [{file, File.read!(file)}])

    assert diagnostics |> resolved() |> Enum.map(&text_at(File.read!(file), &1.primary)) ==
             ["toggle"]

    assert [toggle] = resolved(diagnostics)
    # The spread may pass toggle?, so SpreadLive still receives "toggle".
    assert toggle.message =~ "SoundcheckFixtures.ToggledLive"
    assert toggle.message =~ "SoundcheckFixtures.SpreadLive"
    refute toggle.message =~ "UnfilteredLive"
  end

  describe "a shared component's conditions" do
    setup do
      file = "test/support/fixtures/shared_panel.ex"
      %{panel: file, diagnostics: analyze(UnhandledEvent, [{file, File.read!(file)}])}
    end

    test "make an event another receiver handles unverifiable", %{diagnostics: diagnostics} do
      assert {"resend_invite", :guarded} in unverifiable(diagnostics)
    end

    test "near miss: an event no receiver handles stays resolved", %{
      panel: file,
      diagnostics: diagnostics
    } do
      texts = diagnostics |> resolved() |> Enum.map(&text_at(File.read!(file), &1.primary))
      assert "resend_invte" in texts
    end

    test "near miss: a condition the call site proves stays resolved", %{
      panel: file,
      diagnostics: diagnostics
    } do
      assert [promote] =
               diagnostics
               |> resolved()
               |> Enum.filter(&(text_at(File.read!(file), &1.primary) == "promote"))

      assert promote.message =~ "SoundcheckFixtures.PanelBotsLive"
    end
  end

  test "reads events from keyword attributes" do
    file = "test/support/fixtures/keyword_attrs.ex"
    diagnostics = analyze(UnhandledEvent, [{file, File.read!(file)}])

    assert [typo] = resolved(diagnostics)
    assert typo.message =~ ~S|`phx-click="reloads"`|
    assert typo.suggestion == ~S|Did you mean "reload"?|
    assert text_at(File.read!(file), typo.primary) == "link"
  end

  test "follows render/1 delegation to the template it renders" do
    file = "test/support/fixtures/delegated.ex"
    source = File.read!(file)
    diagnostics = analyze(UnhandledEvent, [{file, source}])

    assert diagnostics |> resolved() |> Enum.map(&text_at(source, &1.primary)) ==
             ["unhandled", "local-missing"]

    assert Enum.all?(
             resolved(diagnostics),
             &(&1.message =~ ~r/DelegatingLive|LocallyDelegatingLive/)
           )
  end

  test "resolves @myself forwarded into function components, recursive ones and delegations included" do
    file = "test/support/fixtures/forwarded_myself.ex"
    source = File.read!(file)
    diagnostics = analyze(UnhandledEvent, [{file, source}])

    assert Enum.all?(diagnostics, &(&1.resolution == :resolved))
    assert Enum.map(diagnostics, &text_at(source, &1.primary)) == ["missing", "act"]
    assert Enum.all?(diagnostics, &(&1.message =~ "SoundcheckFixtures.ForwardedMyselfComponent"))
  end

  test "resolves events in embedded templates, with :suffix and :root, to the rendering LiveView" do
    file = "test/support/fixtures/embedded.ex"
    diagnostics = analyze(UnhandledEvent, [{file, File.read!(file)}])

    assert Enum.all?(diagnostics, &(&1.resolution == :resolved))
    assert Enum.all?(diagnostics, &(&1.message =~ "`SoundcheckFixtures.EmbeddedLive`"))

    assert Enum.map(diagnostics, &{Path.basename(&1.primary.file), event(&1)}) == [
             {"toolbar.html.heex", "embedded-missing"},
             {"profile.html.heex", "suffixed-missing"},
             {"notice.html.heex", "rooted-missing"}
           ]
  end

  defp event(diagnostic), do: text_at(File.read!(diagnostic.primary.file), diagnostic.primary)

  test "a live_session on_mount hook that attaches handle_event makes events unverifiable" do
    file = "test/support/fixtures/session_hooks.ex"

    assert [%{resolution: {:unverifiable, :open_handlers}}] =
             analyze(UnhandledEvent, [{file, File.read!(file)}])
  end
end
