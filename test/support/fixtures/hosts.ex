# LiveViews that run another LiveView's code, for the host inference of
# `Soundcheck.Analysis.LiveHosts`.

# Routed at `/shell`; names its pages in a module attribute.
defmodule SoundcheckFixtures.HostShellLive do
  @moduledoc false
  use Phoenix.LiveView

  @pages %{
    "tab" => SoundcheckFixtures.HostedTabLive,
    "orphan" => SoundcheckFixtures.OrphanPanelLive
  }

  def mount(%{"page" => page}, _session, socket),
    do: {:ok, assign(socket, :page, Map.fetch!(@pages, page))}

  def render(assigns), do: assigns.page.render(assigns)

  def handle_event(event, params, socket),
    do: socket.assigns.page.handle_event(event, params, socket)

  def handle_params(_params, _uri, socket), do: {:noreply, socket}
end

# Has its own route and also runs under `HostShellLive`.
defmodule SoundcheckFixtures.HostedTabLive do
  @moduledoc false
  use Phoenix.LiveView

  def render(assigns), do: ~H"<p></p>"

  def handle_event("shell", _params, socket), do: {:noreply, push_patch(socket, to: "/shell?x=1")}

  def handle_event("other", _params, socket), do: {:noreply, push_patch(socket, to: "/other")}

  def handle_params(_params, _uri, socket), do: {:noreply, socket}
end

defmodule SoundcheckFixtures.OtherLive do
  @moduledoc false
  use Phoenix.LiveView

  def render(assigns), do: ~H"<p></p>"

  def handle_params(_params, _uri, socket), do: {:noreply, socket}
end

# No route renders it; `HostShellLive` names it.
defmodule SoundcheckFixtures.OrphanPanelLive do
  @moduledoc false
  use Phoenix.LiveView

  def render(assigns), do: ~H"<p></p>"

  def handle_event("other", _params, socket), do: {:noreply, push_patch(socket, to: "/other")}
end

# No route renders it and no routed LiveView names it.
defmodule SoundcheckFixtures.UnhostedPanelLive do
  @moduledoc false
  use Phoenix.LiveView

  def render(assigns), do: ~H"<p></p>"

  def handle_event("other", _params, socket), do: {:noreply, push_patch(socket, to: "/other")}
end

# Routed at `/nest` without `handle_params/3`; nests `NestedChildLive`.
defmodule SoundcheckFixtures.NestingLive do
  @moduledoc false
  use Phoenix.LiveView

  def render(assigns) do
    ~H"""
    {live_render(@socket, SoundcheckFixtures.NestedChildLive, id: "child")}
    """
  end
end

# A nested LiveView forwards its patch to the root, `NestingLive`.
defmodule SoundcheckFixtures.NestedChildLive do
  @moduledoc false
  use Phoenix.LiveView

  def render(assigns), do: ~H"<p></p>"

  def handle_event("filter", _params, socket), do: {:noreply, push_patch(socket, to: "/nest?a=1")}
end

# Routed at `/hooked-nest` without `handle_params/3`, but with a hook on
# that stage; nests `HookedChildLive`.
defmodule SoundcheckFixtures.HookedNestingLive do
  @moduledoc false
  use Phoenix.LiveView

  def mount(_params, _session, socket),
    do: {:ok, attach_hook(socket, :params, :handle_params, &params/3)}

  def render(assigns) do
    ~H"""
    {live_render(@socket, SoundcheckFixtures.HookedChildLive, id: "child")}
    """
  end

  defp params(_params, _uri, socket), do: {:halt, socket}
end

defmodule SoundcheckFixtures.HookedChildLive do
  @moduledoc false
  use Phoenix.LiveView

  def render(assigns), do: ~H"<p></p>"

  def handle_event("filter", _params, socket),
    do: {:noreply, push_patch(socket, to: "/hooked-nest?a=1")}
end

# Patches back to itself without `handle_params/3`, but with a hook on that
# stage.
defmodule SoundcheckFixtures.HookedParamsLive do
  @moduledoc false
  use Phoenix.LiveView

  def mount(_params, _session, socket),
    do: {:ok, attach_hook(socket, :params, :handle_params, &params/3)}

  def render(assigns), do: ~H"<p></p>"

  def handle_event("page", _params, socket),
    do: {:noreply, push_patch(socket, to: "/hooked?page=2")}

  defp params(_params, _uri, socket), do: {:halt, socket}
end

# Routed at `/opaque`; compiled without debug info, so the modules it names
# are unknown.
defmodule SoundcheckFixtures.OpaqueShellLive do
  @moduledoc false
  use Phoenix.LiveView

  @compile {:debug_info, false}

  def render(assigns), do: ~H"<p></p>"

  def handle_params(_params, _uri, socket), do: {:noreply, socket}
end

defmodule SoundcheckFixtures.OpaqueGuestLive do
  @moduledoc false
  use Phoenix.LiveView

  def render(assigns), do: ~H"<p></p>"

  def handle_event("opaque", _params, socket), do: {:noreply, push_patch(socket, to: "/opaque")}

  def handle_event("gone", _params, socket), do: {:noreply, push_patch(socket, to: "/gone")}

  def handle_params(_params, _uri, socket), do: {:noreply, socket}
end

defmodule SoundcheckFixtures.HostsRouter do
  @moduledoc false
  use Phoenix.Router

  import Phoenix.LiveView.Router

  # `/gone` routes to a module that does not exist.
  @compile {:no_warn_undefined, SoundcheckFixtures.GoneLive}

  live "/shell", SoundcheckFixtures.HostShellLive, :index
  live "/tab", SoundcheckFixtures.HostedTabLive, :index
  live "/other", SoundcheckFixtures.OtherLive, :index
  live "/nest", SoundcheckFixtures.NestingLive, :index
  live "/hooked-nest", SoundcheckFixtures.HookedNestingLive, :index
  live "/hooked", SoundcheckFixtures.HookedParamsLive, :index
  live "/opaque", SoundcheckFixtures.OpaqueShellLive, :index
  live "/guest", SoundcheckFixtures.OpaqueGuestLive, :index
  # No such module: a route that outlived its LiveView.
  live "/gone", SoundcheckFixtures.GoneLive, :index
end
