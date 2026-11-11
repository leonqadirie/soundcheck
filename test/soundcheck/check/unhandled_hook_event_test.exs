defmodule Soundcheck.Check.Warning.UnhandledHookEventTest do
  use Soundcheck.CheckCase

  import Soundcheck.HeexCase, only: [text_at: 2]

  alias Soundcheck.Check.Warning.UnhandledHookEvent

  @events "test/support/fixtures/events.ex"
  @js [js_paths: ["test/support/fixtures/assets/js"]]

  defp fixture(path), do: [{path, File.read!(path)}]

  describe "UnhandledHookEvent (SC103)" do
    test "fires on a hook push the rendering LiveView does not handle" do
      assert [diagnostic] = analyze(UnhandledHookEvent, fixture(@events), [], @js)

      assert diagnostic.resolution == :resolved
      assert diagnostic.message =~ ~S|Hook `InfiniteScroll` calls `pushEvent("load-more")`|
      assert diagnostic.message =~ "`SoundcheckFixtures.HookedLive`"
      assert text_at(File.read!(@events), diagnostic.anchor) == "InfiniteScroll"
    end

    test "near miss: pushEventTo(this.el) reaches the LiveView that handles it" do
      diagnostics = analyze(UnhandledHookEvent, fixture(@events), [], @js)
      refute Enum.any?(diagnostics, &(&1.message =~ "zoom"))
    end
  end
end
