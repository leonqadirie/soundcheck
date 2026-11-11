defmodule SoundcheckFixtures.ForwardedMyselfComponent do
  @moduledoc false
  use Phoenix.LiveComponent

  def render(assigns) do
    ~H"""
    <div>
      <.row myself={@myself} children={[]} />
      <.panel target={@myself} />
      {actions(assigns)}
    </div>
    """
  end

  # Receives the LiveComponent's @myself directly, and passes it on to
  # itself for nested rows.
  defp row(assigns) do
    ~H"""
    <button phx-click="toggle" phx-target={@myself}>t</button>
    <button phx-click="missing" phx-target={@myself}>m</button>
    <.row :for={child <- @children} myself={@myself} children={child} />
    """
  end

  # Forwards it under another name, one component deeper.
  defp panel(assigns), do: ~H"<.row myself={@target} children={[]} />"

  # Receives the LiveComponent's whole assigns, @myself included.
  defp actions(assigns), do: ~H'<button phx-click="act" phx-target={@myself}>a</button>'

  def handle_event("toggle", _params, socket), do: {:noreply, socket}
end
