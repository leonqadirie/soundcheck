defmodule SoundcheckFixtures.AsyncLive do
  @moduledoc false
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    socket =
      socket
      |> start_async(:load_stats, fn -> 1 end)
      |> start_async(:load_users, fn -> 2 end)
      |> start_async({:fetch, 1}, fn -> 3 end)

    if connected?(socket), do: Process.send_after(self(), :tick, 1000)
    send(self(), {:loaded, 1})
    send(self(), :ping)

    {:ok, socket}
  end

  def render(assigns), do: ~H"<p></p>"

  def handle_async(:load_users, _result, socket), do: {:noreply, socket}
  def handle_async({:fetch, _id}, _result, socket), do: {:noreply, socket}

  def handle_info(:tick, socket), do: {:noreply, socket}
  def handle_info({:loaded, _count}, socket), do: {:noreply, socket}
end

defmodule SoundcheckFixtures.CatchAllLive do
  @moduledoc false
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    send(self(), :anything)
    {:ok, start_async(socket, :anything, fn -> 1 end)}
  end

  def render(assigns), do: ~H"<p></p>"

  def handle_async(_name, _result, socket), do: {:noreply, socket}
  def handle_info(_message, socket), do: {:noreply, socket}
end

defmodule SoundcheckFixtures.AttachedLive do
  @moduledoc false
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    send(self(), :attached)
    {:ok, attach_hook(socket, :listen, :handle_info, &listen/2)}
  end

  def render(assigns), do: ~H"<p></p>"

  defp listen(_message, socket), do: {:cont, socket}
end

defmodule SoundcheckFixtures.NoDebugInfoLive do
  @moduledoc false
  use Phoenix.LiveView

  @compile {:debug_info, false}

  def render(assigns), do: ~H"<p></p>"
end

defmodule SoundcheckFixtures.NotifyingComponent do
  @moduledoc false
  use Phoenix.LiveComponent

  def render(assigns), do: ~H"<p></p>"

  def handle_event("save", _params, socket) do
    send(self(), {:saved, 1})
    send(self(), :closed)
    {:noreply, socket}
  end
end

defmodule SoundcheckFixtures.ParentLive do
  @moduledoc false
  use Phoenix.LiveView

  def render(assigns) do
    ~H"""
    <.live_component module={SoundcheckFixtures.NotifyingComponent} id="notifier" />
    """
  end

  def handle_info({:saved, _id}, socket), do: {:noreply, socket}
end
