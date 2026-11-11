defmodule Soundcheck.Check.InvalidSendUpdateTest do
  use Soundcheck.CheckCase

  import Soundcheck.HeexCase, only: [text_at: 2]

  alias Soundcheck.Check.Warning.InvalidSendUpdate

  @source ~S"""
  defmodule MyApp.Notifier do
    alias SoundcheckFixtures.EventsComponent

    def notify(pid, post) do
      send_update(EventsComponent, post: post)
      send_update(pid, SoundcheckFixtures.EventsLive, id: "x", post: post)
      Phoenix.LiveView.send_update_after(SoundcheckFixtures.Policy, %{id: "x"}, 500)
    end

    def fine(pid, assigns, myself) do
      send_update(EventsComponent, id: "panel", post: nil)
      send_update(pid, EventsComponent, assigns)
      send_update(myself, post: nil)
      send_update(MyApp.NotCompiled, id: "x")
    end
  end
  """

  test "fires on missing ids and on modules that are not LiveComponents" do
    diagnostics = analyze(InvalidSendUpdate, @source)

    assert Enum.map(diagnostics, &text_at(@source, &1.primary)) == [
             "send_update",
             "send_update",
             "send_update_after"
           ]

    assert [no_id, view, plain] = Enum.map(diagnostics, & &1.message)
    assert no_id =~ "names `SoundcheckFixtures.EventsComponent` without an `:id`"
    assert view =~ "`SoundcheckFixtures.EventsLive`, a LiveView"
    assert plain =~ "`SoundcheckFixtures.Policy`, which is not a LiveComponent"
  end

  test "near miss: complete calls, dynamic assigns, CIDs, and unloadable modules" do
    diagnostics = analyze(InvalidSendUpdate, @source)
    refute Enum.any?(diagnostics, &(elem(&1.primary.start, 0) > 8))
  end
end
