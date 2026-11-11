defmodule SoundcheckFixtures.EmbeddedComponents do
  @moduledoc false
  use Phoenix.Component

  embed_templates "embedded/*"
  embed_templates "embedded_cards/*", suffix: "_card"
  embed_templates "banners/*", root: "embedded_shared"
end

defmodule SoundcheckFixtures.EmbeddedLive do
  @moduledoc false
  use Phoenix.LiveView

  alias SoundcheckFixtures.EmbeddedComponents

  def render(assigns) do
    ~H"""
    <EmbeddedComponents.toolbar />
    <EmbeddedComponents.profile_card />
    <EmbeddedComponents.notice />
    """
  end

  def handle_event("embedded-save", _params, socket), do: {:noreply, socket}
end
