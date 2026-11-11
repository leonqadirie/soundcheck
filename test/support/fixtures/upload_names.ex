defmodule SoundcheckFixtures.UploadNamesLive do
  @moduledoc false
  use Phoenix.LiveView

  def mount(_params, _session, socket) do
    {:ok, socket |> allow_upload(:avatar, accept: ~w(.jpg)) |> allow_upload(:cover, accept: :any)}
  end

  def render(assigns) do
    ~H"""
    <form id="upload" phx-submit="save" phx-change="validate">
      <.live_file_input upload={@uploads.avatar} />
      <.live_file_input upload={@uploads[:photo]} />
    </form>
    """
  end

  def handle_event("validate", _params, socket), do: {:noreply, socket}

  def handle_event("save", _params, socket) do
    consume_uploaded_entries(socket, :avatar, fn _meta, _entry -> {:ok, nil} end)
    consume_uploaded_entries(socket, :covers, fn _meta, _entry -> {:ok, nil} end)
    {:noreply, socket}
  end
end
