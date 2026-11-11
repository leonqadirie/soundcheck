defmodule SoundcheckFixtures.GuardedComponents do
  @moduledoc false
  use Phoenix.Component

  attr :filtering?, :boolean, default: true
  attr :toggle?, :boolean, default: false

  def bar(assigns) do
    ~H"""
    <div>
      <form :if={@filtering?} phx-change="filter"></form>
      <button :if={@toggle? && !@filtering?} phx-click="toggle">x</button>
    </div>
    """
  end
end

defmodule SoundcheckFixtures.UnfilteredLive do
  @moduledoc false
  use Phoenix.LiveView

  import SoundcheckFixtures.GuardedComponents

  # Turns filtering off and leaves toggle? at its false default: neither
  # event can render here.
  def render(assigns), do: ~H"<.bar filtering?={false} />"
end

defmodule SoundcheckFixtures.ToggledLive do
  @moduledoc false
  use Phoenix.LiveView

  import SoundcheckFixtures.GuardedComponents

  # Renders "toggle" without handling it.
  def render(assigns), do: ~H"<.bar toggle? filtering?={false} />"

  def handle_event("filter", _params, socket), do: {:noreply, socket}
end

defmodule SoundcheckFixtures.SpreadLive do
  @moduledoc false
  use Phoenix.LiveView

  import SoundcheckFixtures.GuardedComponents

  # The spread may pass toggle?, so "toggle" may render; the literal
  # filtering?={false} still rules out "filter".
  def render(assigns), do: ~H"<.bar filtering?={false} {@rest} />"
end
