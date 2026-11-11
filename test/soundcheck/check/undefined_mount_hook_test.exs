defmodule Soundcheck.Check.UndefinedMountHookTest do
  use Soundcheck.CheckCase

  import Soundcheck.HeexCase, only: [text_at: 2]

  alias Soundcheck.Check.Warning.UndefinedMountHook

  @fixture "test/support/fixtures/mount_hook_declarations.ex"

  defp fixture, do: [{@fixture, File.read!(@fixture)}]

  test "fires on hooks no on_mount/4 clause accepts, at the hook module" do
    diagnostics = analyze(UndefinedMountHook, fixture())
    texts = Enum.map(diagnostics, &text_at(File.read!(@fixture), &1.primary))

    # In the LiveView, then in the router's live_session; a bare module
    # passes :default.
    assert texts == ["AuthHooks", "AuthHooks", "SoundcheckFixtures.AuthHooks"]

    assert [misspelled, admin, default] = Enum.map(diagnostics, & &1.message)
    assert misspelled =~ "No `SoundcheckFixtures.AuthHooks.on_mount/4` clause accepts :misspelled"
    assert admin =~ "accepts :require_admin"
    assert default =~ "accepts :default"
  end

  test "near miss: accepted arguments and non-literal arguments" do
    diagnostics = analyze(UndefinedMountHook, fixture())
    refute Enum.any?(diagnostics, &(&1.message =~ ~r/:loads|:raises|:delegates/))
  end
end
