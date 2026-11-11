defmodule SoundcheckFixtures.SharedPanel do
  @moduledoc false
  use Phoenix.Component

  attr :member, :map, required: true
  attr :admin?, :boolean, default: false

  def panel(assigns) do
    ~H"""
    <div>
      <div :if={@member.kind != :bot}>
        <button phx-click="resend_invite">Resend</button>
        <button phx-click="resend_invte">Typo</button>
      </div>
      <button :if={@admin?} phx-click="promote">Promote</button>
    </div>
    """
  end
end

defmodule SoundcheckFixtures.PanelMembersLive do
  @moduledoc false
  use Phoenix.LiveView

  import SoundcheckFixtures.SharedPanel

  def render(assigns), do: ~H"<.panel member={@member} admin?={true} />"

  def handle_event("resend_invite", _params, socket), do: {:noreply, socket}
  def handle_event("promote", _params, socket), do: {:noreply, socket}
end

defmodule SoundcheckFixtures.PanelBotsLive do
  @moduledoc false
  use Phoenix.LiveView

  import SoundcheckFixtures.SharedPanel

  # Members here are always bots, so "resend_invite" never renders; the
  # literal admin?={true} proves "promote" renders, unhandled.
  def render(assigns), do: ~H"<.panel member={@bot} admin?={true} />"
end
