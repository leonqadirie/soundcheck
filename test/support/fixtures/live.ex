defmodule SoundcheckFixtures.Hooks do
  @moduledoc false
  import Phoenix.Component, only: [assign: 3]

  def on_mount(:default, _params, _session, socket),
    do: {:cont, assign(socket, :current_user, nil)}
end

defmodule SoundcheckFixtures.Components do
  @moduledoc false
  use Phoenix.Component

  attr :title, :string, required: true
  attr :icon, :string, default: nil
  slot :inner_block

  def card(assigns) do
    ~H"""
    <div class="card">{@title}{render_slot(@inner_block)}</div>
    """
  end

  defp plain(assigns), do: ~H"<p></p>"

  def uses_plain(assigns), do: plain(assigns)
end

defmodule SoundcheckFixtures.CounterLive do
  @moduledoc false
  use Phoenix.LiveView

  on_mount {SoundcheckFixtures.Hooks, :default}

  def mount(_params, _session, socket), do: {:ok, assign(socket, count: 0)}

  def render(assigns) do
    ~H"""
    <button phx-click="inc">{@count}</button>
    """
  end

  def handle_event("inc", _params, socket), do: {:noreply, update(socket, :count, &(&1 + 1))}

  def handle_event("row-" <> _id, %{"value" => _value}, socket), do: {:noreply, socket}

  def handle_event(event, _params, socket) when event in ["reset", "clear"],
    do: {:noreply, assign(socket, :count, 0)}
end

defmodule SoundcheckFixtures.FormComponent do
  @moduledoc false
  use Phoenix.LiveComponent

  def render(assigns), do: ~H'<form phx-submit="save" phx-target={@myself}></form>'

  def handle_event("save", _params, socket), do: {:noreply, socket}
end

defmodule SoundcheckFixtures.Router do
  @moduledoc false
  use Phoenix.Router

  import Phoenix.LiveView.Router

  live_session :default, on_mount: [{SoundcheckFixtures.Hooks, :default}] do
    live "/", SoundcheckFixtures.CounterLive, :index
    live "/edit/:id", SoundcheckFixtures.CounterLive, :edit
  end

  live "/outside", SoundcheckFixtures.CounterLive
end

defmodule SoundcheckFixtures.NoDebugInfo do
  @moduledoc false
  @compile {:debug_info, false}

  def handle_event("x", _params, socket), do: {:noreply, socket}
end
