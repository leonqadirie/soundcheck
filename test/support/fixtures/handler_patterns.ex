# Callback heads and senders in the forms `Soundcheck.Analysis.Handlers`
# reads beyond plain literals. `Soundcheck.Analysis.HandlersTest` reads the
# compiled modules through their beams.

defmodule SoundcheckFixtures.PatternsLive do
  @moduledoc false
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    message = {:computed, 1}
    send(self(), {:done, 1, 2})
    send(self(), message)
    send(socket.root_pid, :to_another_process)
    {:ok, socket}
  end

  def render(assigns), do: ~H"<p></p>"

  def handle_event("save" = event, _params, socket), do: {:noreply, assign(socket, :e, event)}
  def handle_event(<<_first, _rest::binary>>, %{"raw" => _}, socket), do: {:noreply, socket}

  def handle_info({:loaded, _id, _rows}, socket), do: {:noreply, socket}
  def handle_info({_ref, _result}, socket), do: {:noreply, socket}
  def handle_info({_ref, _kind, _pid, _reason}, socket), do: {:noreply, socket}
  def handle_info(:tick = message, socket), do: {:noreply, assign(socket, :m, message)}
  def handle_info(%{topic: _topic}, socket), do: {:noreply, socket}
end

defmodule SoundcheckFixtures.GuardedEventsLive do
  @moduledoc false
  use Phoenix.LiveView

  def render(assigns), do: ~H"<p></p>"

  # A guard other than a chain of literal comparisons leaves the clause
  # open to every event.
  def handle_event(event, _params, socket) when is_binary(event), do: {:noreply, socket}
end

defmodule SoundcheckFixtures.TwoGuardsLive do
  @moduledoc false
  use Phoenix.LiveView

  def render(assigns), do: ~H"<p></p>"

  def handle_event(event, _params, socket) when event == "a" when event == "b",
    do: {:noreply, socket}
end
