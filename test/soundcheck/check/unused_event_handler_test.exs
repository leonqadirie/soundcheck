defmodule Soundcheck.Check.Design.UnusedEventHandlerTest do
  use Soundcheck.CheckCase

  import Soundcheck.HeexCase, only: [text_at: 2]

  alias Soundcheck.Check.Design.UnusedEventHandler

  @events "test/support/fixtures/events.ex"
  @dead "test/support/fixtures/dead_handlers.ex"

  defp fixture(path), do: [{path, File.read!(path)}]

  describe "UnusedEventHandler (SC102)" do
    test "fires on a handler nothing emits, in a closed world" do
      assert [diagnostic] = analyze(UnusedEventHandler, fixture(@dead))
      assert diagnostic.message =~ ~S|`handle_event("archive", ...)`|
      assert text_at(File.read!(@dead), diagnostic.primary) == "def"
    end

    test "near miss: an event name used as a string elsewhere is never reported" do
      diagnostics = analyze(UnusedEventHandler, fixture(@dead))
      refute Enum.any?(diagnostics, &(&1.message =~ "referenced"))
    end

    test "reports nothing when any emitter in the project is dynamic" do
      assert [] = analyze(UnusedEventHandler, fixture(@dead) ++ fixture(@events))
    end

    test "near miss: a literal push from a hook helper class exempts its event name" do
      js = [js_paths: ["test/support/fixtures/assets/helper_push_js"]]
      assert [] = analyze(UnusedEventHandler, fixture(@dead), [], js)
    end

    test "reports nothing when a hook helper class pushes a dynamic event" do
      js = [js_paths: ["test/support/fixtures/assets/dynamic_push_js"]]
      assert [] = analyze(UnusedEventHandler, fixture(@dead), [], js)
    end
  end
end
