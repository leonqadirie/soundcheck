defmodule SoundcheckFixtures.DeadHandlerLive do
  @moduledoc false
  use Phoenix.LiveView

  def render(assigns), do: ~H'<button phx-click="used">x</button>'

  def handle_event("used", _params, socket), do: {:noreply, socket}
  def handle_event("archive", _params, socket), do: {:noreply, socket}
  def handle_event("referenced", _params, socket), do: {:noreply, socket}

  def referenced_event, do: "referenced"
end
