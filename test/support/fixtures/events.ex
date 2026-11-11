defmodule SoundcheckFixtures.EventComponents do
  @moduledoc false
  use Phoenix.Component

  attr :label, :string, required: true

  def save_button(assigns), do: ~H'<button phx-click="save">{@label}</button>'

  def orphan_button(assigns), do: ~H'<button phx-click="never-handled">x</button>'

  attr :event, :string, required: true

  def event_button(assigns), do: ~H'<button phx-click={@event}>go</button>'

  attr :on_go, :string, required: true

  def wrapper(assigns), do: ~H'<.event_button event={@on_go} />'
end

defmodule SoundcheckFixtures.EventsLive do
  @moduledoc false
  use Phoenix.LiveView

  import SoundcheckFixtures.EventComponents

  alias Phoenix.LiveView.JS

  def mount(_params, _session, socket), do: {:ok, assign(socket, :action, "inc")}

  def render(assigns) do
    ~H"""
    <div>
      <button phx-click="inc">+</button>
      <button phx-click="incr">typo</button>
      <button phx-click={@action}>dynamic</button>
      <button phx-click={JS.push("inc")}>js</button>
      <button phx-click={JS.push("missing") |> JS.hide(to: "#x")}>js chain</button>
      <.save_button label="Save" />
      <.event_button event="save" />
      <.event_button event="forwarded-missing" />
      <.wrapper on_go="inc" />
      <.local_panel />
      <button phx-click={JS.toggle(to: "#menu")}>no server event</button>
      <button phx-click={toggle("#menu")}>helper without a push</button>
      <button phx-click={JS.push("lv:clear-flash", value: %{key: "info"})}>built in</button>
      <.live_component module={SoundcheckFixtures.EventsComponent} id="panel" />
    </div>
    """
  end

  def toggle(js \\ %JS{}, selector), do: JS.toggle(js, to: selector)

  defp local_panel(assigns) do
    ~H"""
    <button phx-click="inc">handled</button>
    <button phx-click="local-missing">missing</button>
    """
  end

  def handle_event("inc", _params, socket), do: {:noreply, socket}
  def handle_event("save", _params, socket), do: {:noreply, socket}
end

defmodule SoundcheckFixtures.EventsComponent do
  @moduledoc false
  use Phoenix.LiveComponent

  def render(assigns) do
    ~H"""
    <div>
      <button phx-click="toggle" phx-target={@myself}>ok</button>
      <button phx-click="close" phx-target={@myself}>missing in the component</button>
      <button phx-click="inc">goes to the parent LiveView</button>
      <button phx-click="parent-missing">missing in the parent</button>
      <form phx-submit="submit" phx-target="#elsewhere"></form>
    </div>
    """
  end

  def handle_event("toggle", _params, socket), do: {:noreply, socket}
end

defmodule SoundcheckFixtures.HookedLive do
  @moduledoc false
  use Phoenix.LiveView

  def render(assigns) do
    ~H"""
    <div id="feed" phx-hook="InfiniteScroll"></div>
    <div id="chart" phx-hook="Chart"></div>
    """
  end

  def handle_event("zoom", _params, socket), do: {:noreply, socket}
end
