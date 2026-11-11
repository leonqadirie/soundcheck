# Modules whose findings the analyses cannot resolve, one per unverifiable
# reason that needs a compiled module. `Soundcheck.UnverifiableReasonsTest`
# reads this file as source and the compiled modules through their beams.

defmodule SoundcheckFixtures.UndebuggableHook do
  @moduledoc false
  # Without debug info, soundcheck cannot read what the hook assigns or
  # whether it attaches handlers.
  @compile {:debug_info, false}

  def on_mount(:default, _params, _session, socket), do: {:cont, socket}
end

defmodule SoundcheckFixtures.MyselfInViewLive do
  @moduledoc false
  use Phoenix.LiveView

  def render(assigns), do: ~H'<button phx-click="close" phx-target={@myself}>x</button>'
end

defmodule SoundcheckFixtures.UndebuggableLive do
  @moduledoc false
  use Phoenix.LiveView

  @compile {:debug_info, false}

  def render(assigns), do: ~H'<button phx-click="refresh">x</button>'

  def handle_event("other", _params, socket), do: {:noreply, socket}
end

defmodule SoundcheckFixtures.AttachHookLive do
  @moduledoc false
  use Phoenix.LiveView

  def mount(_params, _session, socket),
    do: {:ok, attach_hook(socket, :keys, :handle_event, fn _event, _params, s -> {:cont, s} end)}

  def render(assigns), do: ~H'<button phx-click="hooked">x</button>'

  def handle_event("other", _params, socket), do: {:noreply, socket}
end

defmodule SoundcheckFixtures.UnreadableHookAsyncLive do
  @moduledoc false
  use Phoenix.LiveView

  on_mount SoundcheckFixtures.UndebuggableHook

  def mount(_params, _session, socket), do: {:ok, start_async(socket, :load, fn -> :ok end)}

  def handle_async(:other, _result, socket), do: {:noreply, socket}

  def render(assigns), do: ~H'<p>loading</p>'
end

defmodule SoundcheckFixtures.UnreadableHookAssignsLive do
  @moduledoc false
  use Phoenix.LiveView

  on_mount SoundcheckFixtures.UndebuggableHook

  def mount(_params, _session, socket), do: {:ok, assign(socket, :title, "Stats")}

  def handle_event("refresh", _params, socket), do: {:noreply, assign(socket, :stats, 1)}

  def render(assigns), do: ~H'<h1>{@title}</h1><p>{@stats}</p>'
end

defmodule SoundcheckFixtures.OpenParamsLive do
  @moduledoc false
  use Phoenix.LiveView

  def mount(_params, _session, socket), do: {:ok, assign(socket, :title, "Stats")}

  def handle_params(_params, _uri, socket), do: {:noreply, load(socket)}

  def handle_event("refresh", _params, socket), do: {:noreply, assign(socket, :stats, 1)}

  def render(assigns), do: ~H'<h1>{@title}</h1><p>{@stats}</p>'

  defp load(socket), do: socket
end
