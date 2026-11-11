defmodule SoundcheckFixtures.DelegatedRender do
  @moduledoc false
  use Phoenix.Component

  def render(assigns) do
    ~H"""
    <button phx-click="handled">ok</button>
    <button phx-click="unhandled">x</button>
    <p>{@title} {@never_set}</p>
    """
  end
end

defmodule SoundcheckFixtures.DelegatingLive do
  @moduledoc false
  use Phoenix.LiveView

  def mount(_params, _session, socket), do: {:ok, assign(socket, :title, "Delegated")}

  defdelegate render(assigns), to: SoundcheckFixtures.DelegatedRender

  def handle_event("handled", _params, socket), do: {:noreply, socket}
end

defmodule SoundcheckFixtures.LocallyDelegatingLive do
  @moduledoc false
  use Phoenix.LiveView

  def render(assigns), do: page(assigns)

  defp page(assigns), do: ~H'<button phx-click="local-missing">x</button>'
end
