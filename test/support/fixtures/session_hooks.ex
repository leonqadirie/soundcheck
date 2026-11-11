defmodule SoundcheckFixtures.SessionEventHook do
  @moduledoc false
  # Attaches a handle_event handler to every LiveView in its live_session.

  def on_mount(:default, _params, _session, socket) do
    {:cont,
     Phoenix.LiveView.attach_hook(socket, :logout, :handle_event, fn _event, _params, s ->
       {:cont, s}
     end)}
  end
end

defmodule SoundcheckFixtures.SessionHookedLive do
  @moduledoc false
  use Phoenix.LiveView

  def render(assigns), do: ~H'<button phx-click="logout">x</button>'

  def handle_event("other", _params, socket), do: {:noreply, socket}
end

defmodule SoundcheckFixtures.SessionHookRouter do
  @moduledoc false
  use Phoenix.Router

  import Phoenix.LiveView.Router

  live_session :hooked, on_mount: SoundcheckFixtures.SessionEventHook do
    live "/session-hooked", SoundcheckFixtures.SessionHookedLive, :index
  end
end

defmodule SoundcheckFixtures.CurrentUriHook do
  @moduledoc false
  # Assigns through a captured private helper, the way a handle_params hook
  # usually does.

  def on_mount(:default, _params, _session, socket),
    do: {:cont, Phoenix.LiveView.attach_hook(socket, :uri, :handle_params, &set_current_uri/3)}

  defp set_current_uri(_params, uri, socket), do: {:cont, put_path(socket, uri)}

  defp put_path(socket, uri),
    do: Phoenix.Component.assign(socket, current_path: URI.parse(uri).path)
end
