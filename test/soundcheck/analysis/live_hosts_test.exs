defmodule Soundcheck.Analysis.LiveHostsTest do
  use Soundcheck.CheckCase

  alias Soundcheck.Analysis.LiveHosts
  alias Soundcheck.Graph
  alias SoundcheckFixtures.HostedTabLive
  alias SoundcheckFixtures.HostShellLive
  alias SoundcheckFixtures.NestedChildLive
  alias SoundcheckFixtures.NestingLive
  alias SoundcheckFixtures.OpaqueGuestLive
  alias SoundcheckFixtures.OpaqueShellLive
  alias SoundcheckFixtures.OrphanPanelLive
  alias SoundcheckFixtures.UnhostedPanelLive

  @fixture "test/support/fixtures/hosts.ex"

  defp hosts do
    [{@fixture, File.read!(@fixture)}]
    |> inputs()
    |> Graph.build(js_paths: [])
    |> LiveHosts.infer()
  end

  describe "references/1" do
    test "finds the modules a module attribute holds" do
      assert {:ok, modules} = LiveHosts.references(HostShellLive)

      assert HostedTabLive in modules
      assert OrphanPanelLive in modules
    end

    test "finds a LiveView nested with live_render in a template" do
      assert {:ok, modules} = LiveHosts.references(NestingLive)

      assert NestedChildLive in modules
    end

    test "leaves out the module itself" do
      assert {:ok, modules} = LiveHosts.references(HostShellLive)

      refute HostShellLive in modules
    end

    test "returns the reason a module cannot be read" do
      assert {:error, :no_debug_info} = LiveHosts.references(OpaqueShellLive)
      assert {:error, :not_loadable} = LiveHosts.references(SoundcheckFixtures.NoSuchLive)
    end
  end

  describe "infer/1" do
    test "maps a module to the routed LiveViews that name it" do
      hosts = hosts()

      assert LiveHosts.hosts(hosts, OrphanPanelLive) == [HostShellLive]
      assert LiveHosts.hosts(hosts, NestedChildLive) == [NestingLive]
      assert LiveHosts.hosts(hosts, UnhostedPanelLive) == []
    end

    test "roots/2 puts a routed module before its hosts" do
      hosts = hosts()

      assert LiveHosts.roots(hosts, HostedTabLive) == [HostedTabLive, HostShellLive]
      assert LiveHosts.roots(hosts, OrphanPanelLive) == [HostShellLive]
      assert LiveHosts.roots(hosts, UnhostedPanelLive) == []
    end

    test "records routed LiveViews without debug info as unreadable" do
      hosts = hosts()

      assert LiveHosts.unreadable?(hosts, OpaqueShellLive)
      refute LiveHosts.unreadable?(hosts, OpaqueGuestLive)
      refute LiveHosts.unreadable?(hosts, SoundcheckFixtures.GoneLive)
    end
  end
end
