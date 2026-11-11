defmodule Soundcheck.Check.LiveViewCallbackInComponentTest do
  use Soundcheck.CheckCase

  import Soundcheck.HeexCase, only: [text_at: 2]

  alias Soundcheck.Check.Warning.LiveViewCallbackInComponent

  @source ~S"""
  defmodule MyAppWeb.PostComponent do
    use MyAppWeb, :live_component

    def mount(_params, _session, socket), do: {:ok, socket}

    def handle_info({:saved, _post}, socket), do: {:noreply, socket}

    def handle_event("save", _params, socket) do
      send(self(), {:saved, socket.assigns.post})
      {:noreply, socket}
    end
  end

  defmodule MyAppWeb.ChartComponent do
    use Phoenix.LiveComponent

    def handle_info(:tick, socket), do: {:noreply, socket}
  end

  defmodule MyAppWeb.DashboardLive do
    use MyAppWeb, :live_view
    alias MyAppWeb.ChartComponent

    def handle_info(:tick, socket), do: ChartComponent.handle_info(:tick, socket)
  end
  """

  test "fires on LiveView callbacks in a LiveComponent, at the first clause" do
    diagnostics = analyze(LiveViewCallbackInComponent, @source)

    assert Enum.map(diagnostics, &text_at(@source, &1.primary)) == ["def", "def"]
    assert [mount, info] = Enum.map(diagnostics, & &1.message)

    assert mount =~
             "`MyAppWeb.PostComponent` is a LiveComponent, so LiveView never calls its `mount/3`"

    assert info =~ "reach the parent LiveView's `handle_info/2`"
  end

  test "near miss: callbacks another module calls, and LiveView callbacks in a LiveView" do
    diagnostics = analyze(LiveViewCallbackInComponent, @source)
    refute Enum.any?(diagnostics, &(&1.message =~ ~r/ChartComponent|DashboardLive/))
  end
end
