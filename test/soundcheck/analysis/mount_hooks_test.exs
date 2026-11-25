defmodule Soundcheck.Analysis.MountHooksTest do
  use ExUnit.Case, async: true

  alias Soundcheck.Analysis.Assigns
  alias Soundcheck.Analysis.MountHooks
  alias SoundcheckFixtures.AuthHooks

  test "a hook that always continues cannot halt, through recursive helpers" do
    refute MountHooks.can_halt?(AuthHooks, :loads)
    refute MountHooks.can_halt?(AuthHooks, :recursive)
  end

  test "raising, delegating, and with-without-else results count as able to halt" do
    assert MountHooks.can_halt?(AuthHooks, :raises)
    assert MountHooks.can_halt?(AuthHooks, :delegates)
    assert MountHooks.can_halt?(AuthHooks, :with_no_else)
  end

  test "an argument no clause accepts, or an unloadable module, counts as able to halt" do
    assert MountHooks.can_halt?(AuthHooks, :unknown_arg)
    assert MountHooks.can_halt?(SoundcheckFixtures.Missing, :any)
  end

  describe "hook_modules/2" do
    defp route(view, hooks), do: %{live_view: view, on_mount: Enum.map(hooks, &{&1, :default})}

    test "collects the hooks of every route that points to the LiveView, in route order" do
      route_hooks =
        MountHooks.route_hooks([
          route(DemoLive, [HookA]),
          route(OtherLive, [HookB]),
          route(DemoLive, [HookC, HookA])
        ])

      assert MountHooks.hook_modules(DemoLive, route_hooks) == [HookA, HookC]
      assert MountHooks.hook_modules(OtherLive, route_hooks) == [HookB]
    end

    test "a LiveView no route points to has no route hooks" do
      route_hooks = MountHooks.route_hooks([route(DemoLive, [HookA])])

      assert MountHooks.hook_modules(UnroutedLive, route_hooks) == []
    end
  end

  test "hook keys include those its captured and called helpers assign" do
    assert {:ok, keys} = Assigns.on_mount_keys(SoundcheckFixtures.CurrentUriHook)
    assert MapSet.to_list(keys) == [:current_path]
  end
end
