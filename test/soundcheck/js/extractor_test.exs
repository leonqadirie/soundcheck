defmodule Soundcheck.JS.ExtractorTest do
  use ExUnit.Case, async: true

  import Soundcheck.HeexCase, only: [text_at: 2]

  alias Soundcheck.JS.Extractor

  @app_js ~S"""
  import "phoenix_html"
  import {Socket} from "phoenix"
  import {LiveSocket} from "phoenix_live_view"
  import {hooks as colocatedHooks} from "phoenix-colocated/my_app"
  import topbar from "../vendor/topbar"
  import Chart from "./hooks/chart"

  const Hooks = {
    InfiniteScroll: {
      mounted() {
        this.pushEvent("load-more", {page: 2})
        // this.pushEvent("commented-out")
        const s = "this.pushEvent('in-string')"
        const re = /this.pushEvent\("in-regex"\)/
      }
    },
    Chart,
  }

  Hooks.Copy = {
    mounted() {
      this.el.addEventListener("click", () => this.pushEventTo(this.el, "copied", {}))
    }
  }

  Hooks["Flash"] = {
    mounted() {
      this.handleEvent("flash", ({msg}) => alert(msg))
    }
  }

  let csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
  let liveSocket = new LiveSocket("/live", Socket, {
    longPollFallbackMs: 2500,
    params: {_csrf_token: csrfToken},
    hooks: {...colocatedHooks, ...Hooks},
  })

  window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
  """

  setup do
    %{facts: Extractor.extract(@app_js, file: "assets/js/app.js")}
  end

  test "resolves the hook registry, leaving imported registries open", %{facts: facts} do
    %{names: names, open: open} = Extractor.registry(facts)

    assert names |> Map.keys() |> Enum.sort() == ["Chart", "Copy", "Flash", "InfiniteScroll"]
    assert names["Chart"] == {:ident, "Chart"}
    assert open == [{:import, "phoenix-colocated/my_app", "hooks"}]
    assert facts.imports["Chart"] == {"./hooks/chart", :default}
  end

  test "finds hook events and ignores comments, strings, and regexes", %{facts: facts} do
    %{
      names: %{
        "InfiniteScroll" => {:object, scroll},
        "Copy" => {:object, copy},
        "Flash" => {:object, flash}
      }
    } =
      Extractor.registry(facts)

    assert %{
             pushes: [%{kind: :push_event, event: {:literal, "load-more"}, target: :view}],
             handles: []
           } =
             Extractor.events_in(facts, scroll)

    assert %{pushes: [%{kind: :push_event_to, event: {:literal, "copied"}, target: :self_el}]} =
             Extractor.events_in(facts, copy)

    assert %{pushes: [], handles: [%{event: {:literal, "flash"}}]} =
             Extractor.events_in(facts, flash)

    assert [_load_more, _copied] = facts.pushes
  end

  test "records phx: window listeners", %{facts: facts} do
    assert [%{event: "page-loading-start"}] = facts.window_listeners
  end

  test "records phx: window listeners named by template literals" do
    source = ~S"""
    window.addEventListener(`phx:js-exec`, ({detail}) => liveSocket.execJS(detail.to, detail.attr))
    window.addEventListener(`phx:${name}`, () => {})
    """

    assert [%{event: "js-exec"}] = Extractor.extract(source).window_listeners
  end

  test "reads hook calls through fields the file assigns on this" do
    source = ~S"""
    export default class Connection {
      constructor(hook) {
        this.hook = hook
      }

      send() {
        this.hook.pushEvent("apply_delta", {})
        this.hook.handleEvent("delta_ack", () => {})
        this.unassigned.pushEvent("not-a-hook-call")
        if (this.other === hook) this.other.handleEvent("compared")
      }
    }
    """

    facts = Extractor.extract(source)
    assert [%{event: {:literal, "apply_delta"}, target: :view}] = facts.pushes
    assert [%{event: {:literal, "delta_ack"}}] = facts.handles
  end

  test "push spans cover the call", %{facts: facts} do
    [push | _] = facts.pushes
    assert text_at(@app_js, push.span) == ~S|pushEvent("load-more", {page: 2})|
  end

  test "reads default-exported hooks, dynamic names, selectors, and this aliases" do
    source = ~S"""
    export default {
      mounted() {
        const hook = this
        this.pushEvent(this.el.dataset.event)
        this.pushEvent(`static`)
        this.pushEvent(`row-${this.el.id}`)
        this.pushEventTo("#modal", "close")
        window.setTimeout(() => hook.pushEvent("later"), 10)
        other.pushEvent("not-a-hook-call")
      }
    }
    """

    facts = Extractor.extract(source)
    %{default: {:object, id}} = facts.exports
    %{pushes: pushes} = Extractor.events_in(facts, id)

    assert Enum.map(pushes, &{&1.event, &1.target}) == [
             {:dynamic, :view},
             {{:literal, "static"}, :view},
             {:dynamic, :view},
             {{:literal, "close"}, {:selector, "#modal"}},
             {{:literal, "later"}, :view}
           ]
  end

  test "follows Object.assign and local bindings in the hooks option" do
    source = ~S"""
    const Base = {A: {}}
    const Hooks = {}
    Object.assign(Hooks, Base, {B: {}})
    const opts = {hooks: Hooks}
    new LiveSocket("/live", Socket, opts)
    """

    %{names: names, open: open} = source |> Extractor.extract() |> Extractor.registry()
    assert names |> Map.keys() |> Enum.sort() == ["A", "B"]
    assert open == []
  end

  test "marks computed keys and unknown spreads as open" do
    source = ~S"""
    new LiveSocket("/live", Socket, {hooks: {[name]: {}, ...window.extraHooks, Known: {}}})
    """

    %{names: names, open: open} = source |> Extractor.extract() |> Extractor.registry()
    assert Map.keys(names) == ["Known"]
    assert :dynamic in open
  end

  test "reads qualified LiveSocket constructors" do
    source = ~S"""
    new LiveView.LiveSocket("/live", Socket, {hooks: {A: {}}})
    new window.Phoenix.LiveView.LiveSocket("/live", Socket, {hooks: {B: {}}})
    new LiveSocketish("/live", Socket, {hooks: {C: {}}})
    """

    %{names: names, open: []} = source |> Extractor.extract() |> Extractor.registry()
    assert names |> Map.keys() |> Enum.sort() == ["A", "B"]
  end

  test "member assignments on an imported registry add names" do
    source = ~S"""
    import Hooks from "./hooks"
    Hooks.Local = {}
    new LiveSocket("/live", Socket, {hooks: Hooks})
    """

    %{names: names, open: open} = source |> Extractor.extract() |> Extractor.registry()
    assert Map.keys(names) == ["Local"]
    assert open == [{:import, "./hooks", :default}]
  end

  test "namespace names are the named exports, open for export * and destructuring" do
    closed = ~S"""
    export const A = {}
    export function B() {}
    export async function C() {}
    export class D {}
    export {E as F}
    export default {}
    """

    assert %{names: names, open: []} =
             closed |> Extractor.extract() |> Extractor.namespace_names()

    assert names |> Map.keys() |> Enum.sort() == ["A", "B", "C", "D", "F"]

    for source <- [~S|export * from "./more"|, ~S|export const {G, H} = hooks|] do
      assert %{open: [:dynamic]} = source |> Extractor.extract() |> Extractor.namespace_names()
    end
  end

  test "a file without a LiveSocket registers nothing" do
    assert %{names: names, open: []} =
             "const x = 1" |> Extractor.extract() |> Extractor.registry()

    assert names == %{}
  end
end
