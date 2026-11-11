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

  test "hook keys include those its captured and called helpers assign" do
    assert {:ok, keys} = Assigns.on_mount_keys(SoundcheckFixtures.CurrentUriHook)
    assert MapSet.to_list(keys) == [:current_path]
  end
end
