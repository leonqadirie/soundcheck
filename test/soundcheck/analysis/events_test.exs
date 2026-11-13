defmodule Soundcheck.Analysis.EventsTest do
  use ExUnit.Case, async: true

  import Soundcheck.HeexCase, only: [element: 2]

  alias Soundcheck.Analysis.Components.Index
  alias Soundcheck.Analysis.Events
  alias Soundcheck.Analysis.Events.Emitter
  alias Soundcheck.Heex.Parser
  alias SoundcheckFixtures.EventComponents
  alias SoundcheckFixtures.EventsComponent
  alias SoundcheckFixtures.EventsLive

  @empty %Index{sites: %{}, delegators: %{}}

  defp emitters(source), do: Events.emitters(Parser.parse(source))

  defp emitter(source) do
    [emitter] = emitters(source)
    emitter
  end

  # A template that `owner` renders. `EventComponents` is a compiled module
  # that is neither a LiveView nor a LiveComponent, so any function name
  # under it reads as a function component.
  defp template(source, owner), do: Parser.parse(source, owner: owner, origin: :sigil)

  # An index in which `template`'s `<.tag>` element is the only call site of
  # `callee`.
  defp index(callee, template, tag),
    do: %Index{sites: %{callee => [{template, element(template.root, tag)}]}, delegators: %{}}

  describe "emitters/2 events" do
    test "a JS.push after a JS argument, and through the full alias, names its event" do
      assert %Emitter{event: {:literal, "save"}, via: "JS.push"} =
               emitter(~S|<button phx-click={JS.push(%JS{}, "save")}>x</button>|)

      # The span covers the qualified call name as written.
      assert %Emitter{event: {:literal, "save"}, span: %{start: {1, 20}, stop: {1, 44}}} =
               emitter(~S|<button phx-click={Phoenix.LiveView.JS.push("save")}>x</button>|)
    end

    test "a JS.push whose event is not a literal is dynamic" do
      assert %Emitter{event: :dynamic, via: "JS.push"} =
               emitter(~S|<button phx-click={JS.push(@event)}>x</button>|)
    end

    test "an attr read forwards; any other expression is dynamic" do
      assert emitter(~S|<button phx-click={@event}>x</button>|).event == {:forward, :event}
      assert emitter(~S|<button phx-click={event_name(@row)}>x</button>|).event == :dynamic
    end

    test "an expression that does not parse is dynamic" do
      assert emitter(~S|<button phx-click={broken(}>x</button>|).event == :dynamic
    end

    test "near miss: a bare event attribute emits nothing" do
      assert emitters(~S|<button phx-click>x</button>|) == []
    end
  end

  describe "emitters/2 targets" do
    test "reads phx-target as a selector, @myself, another assign, or dynamic" do
      for {target, expected} <- [
            {~S|phx-target="#modal"|, {:selector, "#modal"}},
            {~S|phx-target={"#modal"}|, {:selector, "#modal"}},
            {~S|phx-target={@myself}|, :myself},
            {~S|phx-target={@panel}|, {:assign, :panel}},
            {~S|phx-target={target_for(@row)}|, :dynamic},
            {~S|phx-target|, :dynamic},
            {"", :none}
          ] do
        assert emitter(~s|<button phx-click="go" #{target}>x</button>|).target == expected
      end
    end

    test "a JS.push target option overrides the element's phx-target" do
      source =
        ~S|<button phx-target="#outer" phx-click={JS.push("go", target: @myself)}>x</button>|

      assert emitter(source).target == :myself
    end

    test "a JS.push without a target option takes the element's phx-target" do
      source =
        ~S|<button phx-target={@myself} phx-click={JS.push("go", value: %{id: 1})}>x</button>|

      assert %Emitter{target: :myself, value: {:%{}, _, [id: 1]}} = emitter(source)
    end
  end

  describe "receiver_reach/3" do
    test "a dynamic or forwarded event is unverifiable" do
      template = template(~S|<button phx-click={name()}>x</button>|, {EventsLive, :render})
      [emitter] = Events.emitters(template)

      assert Events.receiver_reach(template, emitter, @empty) == {:unverifiable, :dynamic_event}
      assert Events.receivers(template, emitter, @empty) == {:unverifiable, :dynamic_event}
    end

    test "a dynamic target is unverifiable" do
      source = ~S|<button phx-click="go" phx-target={target_for(@row)}>x</button>|
      template = template(source, {EventsLive, :render})
      [emitter] = Events.emitters(template)

      assert Events.receiver_reach(template, emitter, @empty) == {:unverifiable, :dynamic_target}
    end

    test "a template without an owner has no render path and no component to target" do
      untargeted = Parser.parse(~S|<button phx-click="go">x</button>|)
      [emitter] = Events.emitters(untargeted)

      assert Events.receiver_reach(untargeted, emitter, @empty) ==
               {:unverifiable, :no_render_path}

      targeted = Parser.parse(~S|<button phx-click="go" phx-target={@myself}>x</button>|)
      [emitter] = Events.emitters(targeted)
      assert Events.receiver_reach(targeted, emitter, @empty) == {:unverifiable, :dynamic_target}
    end

    test "an untargeted event in a LiveView's render reaches that LiveView" do
      template = template(~S|<button phx-click="go">x</button>|, {EventsLive, :render})
      [emitter] = Events.emitters(template)

      assert Events.receiver_reach(template, emitter, @empty) == {:ok, %{EventsLive => false}}
    end

    test "an untargeted event under a condition reaches its LiveView guarded" do
      source = ~S|<%= if @admin? do %><button phx-click="go">x</button><% end %>|
      template = template(source, {EventsLive, :render})
      [emitter] = Events.emitters(template)

      assert Events.receiver_reach(template, emitter, @empty) == {:ok, %{EventsLive => true}}
    end
  end

  describe "receiver_reach/3 for a target a function component takes from an attr" do
    @panel {:function, EventComponents, :panel}
    @button ~S|<button phx-click="go" phx-target={@target}>x</button>|

    defp reach(index) do
      template = template(@button, {EventComponents, :panel})
      [emitter] = Events.emitters(template)
      Events.receiver_reach(template, emitter, index)
    end

    test "a LiveComponent's render that passes @myself receives the event" do
      site = template(~S|<.panel target={@myself} />|, {EventsComponent, :render})

      assert reach(index(@panel, site, ".panel")) == {:ok, %{EventsComponent => false}}
    end

    test "a LiveView's render that passes @myself names no component" do
      site = template(~S|<.panel target={@myself} />|, {EventsLive, :render})

      assert reach(index(@panel, site, ".panel")) == {:unverifiable, :myself_outside_component}
    end

    test "a render that passes one of its own socket assigns is unverifiable" do
      site = template(~S|<.panel target={@selected} />|, {EventsComponent, :render})

      assert reach(index(@panel, site, ".panel")) == {:unverifiable, :dynamic_target}
    end

    test "a call site that passes anything but an attr read is unverifiable" do
      for attrs <- [~S|target="#modal"|, "target={target_for(@row)}", ""] do
        site = template("<.panel #{attrs} />", {EventsComponent, :render})

        assert reach(index(@panel, site, ".panel")) == {:unverifiable, :dynamic_target}
      end
    end

    test "a component nobody renders has no render path" do
      assert reach(@empty) == {:unverifiable, :no_render_path}
    end

    test "a recursive component adds no receivers of its own" do
      site = template(~S|<.panel target={@target} />|, {EventComponents, :panel})

      assert reach(index(@panel, site, ".panel")) == {:ok, %{}}
    end

    test "one unverifiable call site makes the whole target unverifiable" do
      resolved = template(~S|<.panel target={@myself} />|, {EventsComponent, :render})
      dynamic = template(~S|<.panel target="#modal" />|, {EventsComponent, :render})

      index = %Index{
        sites: %{
          @panel => [
            {resolved, element(resolved.root, ".panel")},
            {dynamic, element(dynamic.root, ".panel")}
          ]
        },
        delegators: %{}
      }

      assert reach(index) == {:unverifiable, :dynamic_target}
    end

    # `panel` rendered through a chain of function components, each passing
    # `target` on, up to a LiveComponent's render that passes `@myself`.
    defp chain(components) do
      callers = tl(components) ++ [:render]

      sites =
        for {callee, caller} <- Enum.zip(components, callers), into: %{} do
          {owner, value} =
            if caller == :render,
              do: {{EventsComponent, :render}, "@myself"},
              else: {{EventComponents, caller}, "@target"}

          site = template("<.#{callee} target={#{value}} />", owner)
          {{:function, EventComponents, callee}, [{site, element(site.root, ".#{callee}")}]}
        end

      %Index{sites: sites, delegators: %{}}
    end

    test "follows a target forwarded through four function components" do
      assert reach(chain([:panel, :p1, :p2, :p3])) == {:ok, %{EventsComponent => false}}
    end

    test "gives up on a target forwarded through a fifth" do
      assert reach(chain([:panel, :p1, :p2, :p3, :p4])) == {:unverifiable, :dynamic_target}
    end
  end

  describe "expand/3" do
    @event_button {:function, EventComponents, :event_button}

    defp forwarding do
      template =
        template(~S|<button phx-click={@event}>x</button>|, {EventComponents, :event_button})

      [emitter] = Events.emitters(template)
      {template, emitter}
    end

    defp expand(index) do
      {template, emitter} = forwarding()
      Events.expand(template, emitter, index)
    end

    test "a literal or dynamic event comes back unchanged" do
      template = template(~S|<button phx-click="go">x</button>|, {EventsLive, :render})
      [emitter] = Events.emitters(template)

      assert Events.expand(template, emitter, @empty) == [{:ok, template, emitter}]
    end

    test "a literal at the call site becomes an emitter there" do
      site = template(~S|<.event_button event="save" />|, {EventsLive, :render})

      assert [{:ok, ^site, %Emitter{event: {:literal, "save"}, target: :none, via: "phx-click"}}] =
               expand(index(@event_button, site, ".event_button"))
    end

    test "a JS.push at the call site contributes its events" do
      site =
        template(
          ~S'<.event_button event={JS.push("save") |> JS.push("log", target: @myself)} />',
          {EventsLive, :render}
        )

      assert [
               {:ok, ^site, %Emitter{event: {:literal, "save"}, target: :none}},
               {:ok, ^site, %Emitter{event: {:literal, "log"}, target: :myself}}
             ] = expand(index(@event_button, site, ".event_button"))
    end

    test "any other expression at the call site is a dynamic event" do
      site = template(~S|<.event_button event={event_for(@row)} />|, {EventsLive, :render})

      assert expand(index(@event_button, site, ".event_button")) ==
               [{:unverifiable, :dynamic_event}]
    end

    test "near miss: a bare attr at the call site names no event" do
      site = template(~S|<.event_button event />|, {EventsLive, :render})

      assert expand(index(@event_button, site, ".event_button")) == []
    end

    test "a component nobody renders has no render path" do
      assert expand(@empty) == [{:unverifiable, :no_render_path}]
    end

    test "a component a function delegates its assigns to takes the event from a socket assign" do
      index = %Index{sites: %{}, delegators: %{@event_button => [{EventsLive, :render}]}}

      assert expand(index) == [{:unverifiable, :dynamic_event}]
    end

    test "a forwarded event with a target is unverifiable" do
      template =
        template(
          ~S|<button phx-click={@event} phx-target={@myself}>x</button>|,
          {EventComponents, :event_button}
        )

      [emitter] = Events.emitters(template)

      assert Events.expand(template, emitter, @empty) == [{:unverifiable, :dynamic_target}]
    end

    test "a forwarded event in a LiveView's render or an ownerless template is a socket assign" do
      for template <- [
            template(~S|<button phx-click={@event}>x</button>|, {EventsLive, :render}),
            Parser.parse(~S|<button phx-click={@event}>x</button>|)
          ] do
        [emitter] = Events.emitters(template)
        assert Events.expand(template, emitter, @empty) == [{:unverifiable, :dynamic_event}]
      end
    end

    test "gives up on an event forwarded through more than three components" do
      site = template(~S|<.event_button event={@event} />|, {EventComponents, :event_button})

      assert expand(index(@event_button, site, ".event_button")) ==
               [{:unverifiable, :dynamic_event}]
    end
  end
end
