defmodule SoundcheckFixtures.UnsetLive do
  @moduledoc false
  use Phoenix.LiveView

  def mount(params, _session, socket) do
    socket = assign(socket, :title, "Stats")

    socket =
      if params["full"], do: assign(socket, :mode, :full), else: assign(socket, :mode, :short)

    socket = if params["debug"], do: assign(socket, :debug, true), else: socket
    {:ok, socket}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, assign(socket, :page, 1)}

  def handle_event("refresh", _params, socket), do: {:noreply, assign(socket, :stats, 1)}

  def render(assigns) do
    ~H"""
    <h1>{@title} {@mode} {@page} {@current_user}</h1>
    <p>{@stats}</p>
    <p>{@debug}</p>
    <p :if={@title}>{@hidden_detail}</p>
    <%= if @mode == :full do %>{@full_only}<% end %>
    """
  end
end
