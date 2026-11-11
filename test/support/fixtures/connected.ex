defmodule SoundcheckFixtures.ConnectedLive do
  @moduledoc false
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    socket = assign(socket, :title, "Dashboard")

    socket =
      if connected?(socket),
        do: assign(socket, stats: 1, chart: 2),
        else: assign(socket, :chart, nil)

    {:ok, socket}
  end

  def render(assigns), do: ~H"<h1>{@title}</h1><p>{@stats}</p><div>{@chart}</div>"
end

defmodule SoundcheckFixtures.ConnectedParamsLive do
  @moduledoc false
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    if connected?(socket), do: {:ok, assign(socket, :stats, 1)}, else: {:ok, socket}
  end

  def handle_params(_params, _uri, socket),
    do: {:noreply, assign_new(socket, :stats, fn -> 0 end)}

  def render(assigns), do: ~H"<p>{@stats}</p>"
end

defmodule SoundcheckFixtures.ConnectedOpenLive do
  @moduledoc false
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    socket = if connected?(socket), do: assign(socket, :stats, 1), else: load_defaults(socket)
    {:ok, socket}
  end

  def render(assigns), do: ~H"<p>{@stats}</p>"

  defp load_defaults(socket), do: assign(socket, :stats, 0)
end
