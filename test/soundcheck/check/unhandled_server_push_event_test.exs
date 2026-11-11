defmodule Soundcheck.Check.Warning.UnhandledServerPushEventTest do
  use Soundcheck.CheckCase

  import Soundcheck.HeexCase, only: [text_at: 2]

  alias Soundcheck.Check.Warning.UnhandledServerPushEvent

  @js [js_paths: ["test/support/fixtures/assets/js"]]

  @source ~S"""
  defmodule MyAppWeb.NotesLive do
    use MyAppWeb, :live_view

    def handle_event("copy", _params, socket) do
      {:noreply, push_event(socket, "copied", %{})}
    end

    def handle_event("copy-typo", _params, socket) do
      {:noreply, socket |> push_event("copyed", %{})}
    end

    def handle_event("dynamic", %{"name" => name}, socket) do
      {:noreply, Phoenix.LiveView.push_event(socket, name, %{})}
    end
  end
  """

  test "fires on a push no JavaScript listens for, through pipes too" do
    assert [diagnostic] = analyze(UnhandledServerPushEvent, @source, [], @js)

    assert diagnostic.resolution == :resolved
    assert diagnostic.message =~ ~S|"copyed"|
    assert diagnostic.suggestion == ~S|Did you mean "copied"?|
    assert text_at(@source, diagnostic.primary) == "push_event"
  end

  test "near miss: a hook handleEvent listener handles the push" do
    diagnostics = analyze(UnhandledServerPushEvent, @source, [], @js)
    refute Enum.any?(diagnostics, &(&1.message =~ ~S|"copied"|))
  end

  test "without a LiveSocket, findings are unverifiable" do
    diagnostics = analyze(UnhandledServerPushEvent, @source)
    assert [_copied, _copyed] = diagnostics
    assert Enum.all?(diagnostics, &(&1.resolution == {:unverifiable, :no_live_socket}))
  end
end
