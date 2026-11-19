defmodule Soundcheck.Check.HostInferenceTest do
  # SC701 and SC703 over LiveViews that run under another LiveView: the
  # root view LiveView validates a patch against is not the calling module.
  use Soundcheck.CheckCase

  alias Soundcheck.Check.Warning.PatchToForeignLiveView
  alias Soundcheck.Check.Warning.PatchWithoutHandleParams
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph
  alias Soundcheck.Span

  @fixture "test/support/fixtures/hosts.ex"

  defp fixture, do: [{@fixture, File.read!(@fixture)}]

  # The diagnostics `check` reports inside the fixture module `module`.
  defp diagnostics_in(check, module) do
    graph = Graph.build(inputs(fixture()), js_paths: [])
    span = Graph.module(graph, module).span

    for diagnostic <- analyze(check, fixture()),
        Span.contains?(span, diagnostic.primary.start),
        do: diagnostic
  end

  defp resolved(diagnostics), do: Enum.reject(diagnostics, &Diagnostic.unverifiable?/1)

  defp unverifiable(diagnostics), do: Enum.filter(diagnostics, &Diagnostic.unverifiable?/1)

  describe "PatchToForeignLiveView (SC701)" do
    test "fires on a patch to a route whose LiveView does not load" do
      # A module that does not load runs nothing, so it is no host.
      assert [diagnostic] =
               resolved(
                 diagnostics_in(PatchToForeignLiveView, SoundcheckFixtures.OpaqueGuestLive)
               )

      assert diagnostic.message =~ "rendered by SoundcheckFixtures.GoneLive; LiveView raises."
    end

    test "near miss: an unrouted LiveView patching to the route of a LiveView that names it" do
      # `NestedChildLive` is nested in `NestingLive` and patches to `/nest`.
      assert [] = diagnostics_in(PatchToForeignLiveView, SoundcheckFixtures.NestedChildLive)
    end

    test "fires on a routed LiveView patching to a route outside its hosts" do
      # `HostedTabLive` patches to `/other`.
      assert [diagnostic] =
               resolved(diagnostics_in(PatchToForeignLiveView, SoundcheckFixtures.HostedTabLive))

      assert diagnostic.message =~ "rendered by SoundcheckFixtures.OtherLive; LiveView raises."
    end

    test "unverifiable: a routed LiveView patching to the route of a LiveView that names it" do
      # `HostedTabLive` patches to `/shell`: valid under `HostShellLive`,
      # a raise when `HostedTabLive` is mounted at its own route `/tab`.
      assert [diagnostic] =
               unverifiable(
                 diagnostics_in(PatchToForeignLiveView, SoundcheckFixtures.HostedTabLive)
               )

      assert diagnostic.resolution == {:unverifiable, :hosted_live_view}

      assert diagnostic.message =~
               "SoundcheckFixtures.HostShellLive names `SoundcheckFixtures.HostedTabLive`"
    end

    test "unverifiable: an unrouted LiveView patching to a route outside its hosts" do
      assert [diagnostic] =
               diagnostics_in(PatchToForeignLiveView, SoundcheckFixtures.OrphanPanelLive)

      assert diagnostic.resolution == {:unverifiable, :unrouted_live_view}

      assert diagnostic.message =~
               "and SoundcheckFixtures.HostShellLive, which names it, renders another route"

      assert diagnostic.message =~ "valid only if SoundcheckFixtures.OtherLive runs this code"
    end

    test "unverifiable: an unrouted LiveView that no routed LiveView names" do
      assert [diagnostic] =
               diagnostics_in(PatchToForeignLiveView, SoundcheckFixtures.UnhostedPanelLive)

      assert diagnostic.resolution == {:unverifiable, :unrouted_live_view}

      assert diagnostic.message =~
               "No live route soundcheck read renders `SoundcheckFixtures.UnhostedPanelLive`, so"
    end

    test "unverifiable: the target LiveView carries no readable debug info" do
      assert [diagnostic] =
               unverifiable(
                 diagnostics_in(PatchToForeignLiveView, SoundcheckFixtures.OpaqueGuestLive)
               )

      assert diagnostic.resolution == {:unverifiable, :unreadable_host}

      assert diagnostic.message =~
               "Soundcheck cannot read SoundcheckFixtures.OpaqueShellLive, which may run this code"
    end
  end

  describe "PatchWithoutHandleParams (SC703)" do
    test "fires on a patch to the route of a host without handle_params/3" do
      assert [diagnostic] = resolved(analyze(PatchWithoutHandleParams, fixture()))

      assert diagnostic.message =~ "This patch from `SoundcheckFixtures.NestedChildLive`"

      assert diagnostic.message =~
               "rendered by `SoundcheckFixtures.NestingLive`, which names it and defines no " <>
                 "`handle_params/3`"
    end

    test "unverifiable: the host attaches a handle_params hook" do
      # A hook that halts keeps LiveView from calling `handle_params/3`.
      assert [diagnostic] =
               diagnostics_in(PatchWithoutHandleParams, SoundcheckFixtures.HookedChildLive)

      assert diagnostic.resolution == {:unverifiable, :attach_hook}
      assert diagnostic.message =~ "rendered by `SoundcheckFixtures.HookedNestingLive`"
    end

    test "unverifiable: a LiveView patching back to itself attaches a handle_params hook" do
      assert [diagnostic] =
               diagnostics_in(PatchWithoutHandleParams, SoundcheckFixtures.HookedParamsLive)

      assert diagnostic.resolution == {:unverifiable, :attach_hook}
      assert diagnostic.message =~ "returns to `SoundcheckFixtures.HookedParamsLive`"
    end

    test "near miss: hosts and targets that define handle_params/3" do
      for module <- [
            SoundcheckFixtures.HostedTabLive,
            SoundcheckFixtures.OrphanPanelLive,
            SoundcheckFixtures.OpaqueGuestLive
          ] do
        assert [] = diagnostics_in(PatchWithoutHandleParams, module)
      end
    end
  end
end
