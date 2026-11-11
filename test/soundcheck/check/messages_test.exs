defmodule Soundcheck.Check.MessagesTest do
  use Soundcheck.CheckCase, async: false

  import Soundcheck.HeexCase, only: [text_at: 2]

  alias Soundcheck.Check.Consistency.Configuration
  alias Soundcheck.Check.Warning.UnhandledAsyncResult
  alias Soundcheck.Check.Warning.UnhandledInfoMessage

  @fixture "test/support/fixtures/messages.ex"

  defp fixture, do: [{@fixture, File.read!(@fixture)}]

  describe "UnhandledAsyncResult (SC104)" do
    test "fires on a start_async name without a handle_async clause" do
      assert [diagnostic] = analyze(UnhandledAsyncResult, fixture())
      assert diagnostic.message =~ "`start_async` with name `:load_stats`"
      assert diagnostic.message =~ "SoundcheckFixtures.AsyncLive"
      assert text_at(File.read!(@fixture), diagnostic.primary) == "start_async"
      assert diagnostic.resolution == :resolved
    end

    test "near miss: a catch-all handle_async accepts every name" do
      diagnostics = analyze(UnhandledAsyncResult, fixture())
      refute Enum.any?(diagnostics, &(&1.message =~ "CatchAllLive"))
    end
  end

  describe "UnhandledInfoMessage (SC107)" do
    test "fires on a message with no handle_info clause and skips handled ones" do
      diagnostics = analyze(UnhandledInfoMessage, fixture())

      resolved =
        Enum.filter(diagnostics, &(&1.resolution == :resolved and &1.message =~ "AsyncLive"))

      assert [ping] = resolved
      assert ping.message =~ "sends `:ping`"
      assert text_at(File.read!(@fixture), ping.primary) == "send"
    end

    test "checks a LiveComponent's messages against the LiveViews that render it" do
      diagnostics = analyze(UnhandledInfoMessage, fixture())

      assert [closed] = Enum.filter(diagnostics, &(&1.message =~ "NotifyingComponent"))
      assert closed.message =~ "sends `:closed` to its parent LiveView"
      assert closed.message =~ "`SoundcheckFixtures.ParentLive` has no matching"
      assert text_at(File.read!(@fixture), closed.primary) == "send"
    end

    test "attach_hook makes the finding unverifiable" do
      diagnostics = analyze(UnhandledInfoMessage, fixture())

      assert [attached] = Enum.filter(diagnostics, &(&1.message =~ "AttachedLive"))
      assert attached.resolution == {:unverifiable, :attach_hook}
    end

    test "unverifiable findings reach Credo only in strict mode" do
      assert [_ping, _closed] =
               run_check(UnhandledInfoMessage, fixture(), @fixture, excluded_paths: [])

      assert [_ping, _attached, _closed] =
               run_check(UnhandledInfoMessage, fixture(), @fixture,
                 excluded_paths: [],
                 strict: true
               )
    end
  end

  describe "Configuration (SC000)" do
    test "reports LiveViews that cannot be loaded or carry no debug info" do
      source = """
      defmodule NotCompiledLive do
        use Phoenix.LiveView
      end
      """

      diagnostics = analyze(Configuration, [{"lib/not_compiled_live.ex", source} | fixture()])
      messages = Enum.map(diagnostics, & &1.message)

      assert Enum.any?(messages, &(&1 =~ "Could not load `NotCompiledLive`"))

      assert Enum.any?(
               messages,
               &(&1 =~ "`SoundcheckFixtures.NoDebugInfoLive` was compiled without debug info")
             )

      assert [_not_loadable, _no_debug_info] = diagnostics
    end

    test "stays silent for compiled modules" do
      assert [] =
               analyze(Configuration, [
                 {"test/support/fixtures/live.ex", File.read!("test/support/fixtures/live.ex")}
               ])
    end
  end
end
