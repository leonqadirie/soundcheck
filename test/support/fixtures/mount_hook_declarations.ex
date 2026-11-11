defmodule SoundcheckFixtures.HookDeclarationsLive do
  @moduledoc false
  use Phoenix.LiveView

  alias SoundcheckFixtures.AuthHooks

  on_mount {AuthHooks, :loads}
  on_mount {AuthHooks, :misspelled}

  def render(assigns), do: ~H"<p></p>"
end

defmodule SoundcheckFixtures.HookDeclarationsRouter do
  @moduledoc false
  use Phoenix.Router

  import Phoenix.LiveView.Router

  alias SoundcheckFixtures.AuthHooks

  # A non-literal argument: the check skips it.
  @dynamic_arg :delegates

  live_session :valid, on_mount: [{AuthHooks, :raises}, {AuthHooks, @dynamic_arg}] do
    live "/hooks/valid", SoundcheckFixtures.HookDeclarationsLive, :index
  end

  scope "/hooks" do
    live_session :broken,
      on_mount: [
        {AuthHooks, :require_admin},
        SoundcheckFixtures.AuthHooks
      ] do
      live "/broken", SoundcheckFixtures.HookDeclarationsLive, :index
    end
  end
end
