defmodule Soundcheck.Analysis.GuardsTest do
  use ExUnit.Case, async: true

  import Soundcheck.HeexCase, only: [element: 2]

  alias Soundcheck.Analysis.Guards
  alias Soundcheck.Heex.Parser
  alias SoundcheckFixtures.GuardedComponents

  # The conditions and guards around the template's `<button>`.
  defp conditions(source) do
    template = Parser.parse(source)
    Guards.conditions(template.root, element(template.root, "button").span)
  end

  defp guards(source) do
    template = Parser.parse(source)
    template.root |> Guards.at(element(template.root, "button").span) |> Enum.sort()
  end

  # The call site `<.bar ...>` with the given attributes.
  defp site(attrs) do
    template = Parser.parse("<.bar #{attrs} />")
    element(template.root, ".bar")
  end

  @bar {:function, GuardedComponents, :bar}

  describe "conditions/2" do
    test "an :if that reads only guards lists them" do
      assert conditions(~S|<button :if={@admin? && not @locked?}>x</button>|) ==
               [{:guards, [admin?: :truthy, locked?: :falsy]}]
    end

    test "a double negation keeps the truthiness" do
      assert conditions(~S|<button :if={!!@admin?}>x</button>|) == [{:guards, [admin?: :truthy]}]
    end

    test "any other :if is opaque" do
      assert conditions(~S|<button :if={@user.role == :admin}>x</button>|) == [:opaque]
      assert conditions(~S'<button :if={@a || @b}>x</button>') == [:opaque]
      assert conditions(~S|<button :if={!(@a && @b)}>x</button>|) == [:opaque]
      assert conditions(~S|<button :if="true">x</button>|) == [:opaque]
    end

    test "an enclosing EEx if, unless, case, or cond is opaque" do
      assert conditions("<%= if @admin? do %><button>x</button><% end %>") == [:opaque]
      assert conditions("<%= unless @locked? do %><button>x</button><% end %>") == [:opaque]

      assert conditions("""
             <%= case @role do %>
               <% :admin -> %><button>x</button>
               <% _other -> %><p>none</p>
             <% end %>
             """) == [:opaque]

      assert conditions("""
             <%= cond do %>
               <% @admin? -> %><button>x</button>
               <% true -> %><p>none</p>
             <% end %>
             """) == [:opaque]
    end

    test "near miss: an enclosing EEx for is no condition" do
      assert conditions("<%= for row <- @rows do %><button>{row}</button><% end %>") == []
    end

    test "near miss: an EEx if beside the location is no condition" do
      assert conditions("<%= if @admin? do %><p>x</p><% end %><button>x</button>") == []
    end

    test "lists the conditions outermost first" do
      assert conditions("""
             <div :if={@open?}>
               <%= if @user.admin do %>
                 <button :if={!@locked?}>x</button>
               <% end %>
             </div>
             """) == [{:guards, [open?: :truthy]}, :opaque, {:guards, [locked?: :falsy]}]
    end
  end

  describe "at/2" do
    test "reads the guards of every enclosing element, through EEx blocks" do
      assert guards("""
             <div :if={@open?}>
               <%= for row <- @rows do %>
                 <button :if={!@locked?}>{row}</button>
               <% end %>
             </div>
             """) == [locked?: :falsy, open?: :truthy]
    end

    test "reads the guards a partly opaque :if still names" do
      assert guards(~S|<button :if={@admin? && @user.active}>x</button>|) == [admin?: :truthy]
    end
  end

  describe "holds?/3 and excluded?/3" do
    @truthy [{:guards, [flag: :truthy]}]

    test "a literal, a string, and a bare attribute are known values" do
      for attrs <- ["flag={true}", ~S|flag="yes"|, "flag"] do
        assert Guards.holds?(@truthy, site(attrs), @bar)
        refute Guards.excluded?([flag: :truthy], site(attrs), @bar)
      end

      for attrs <- ["flag={false}", "flag={nil}"] do
        refute Guards.holds?(@truthy, site(attrs), @bar)
        assert Guards.excluded?([flag: :truthy], site(attrs), @bar)
        assert Guards.holds?([{:guards, [flag: :falsy]}], site(attrs), @bar)
      end
    end

    test "an expression proves and rules out nothing" do
      refute Guards.holds?(@truthy, site("flag={@flag}"), @bar)
      refute Guards.excluded?([flag: :truthy], site("flag={@flag}"), @bar)
      refute Guards.excluded?([flag: :falsy], site("flag={@flag}"), @bar)
    end

    test "a spread before the attr may set it, so the attr is unknown" do
      refute Guards.holds?(@truthy, site("{@rest} flag={true}"), @bar)
      refute Guards.excluded?([flag: :truthy], site("{@rest} flag={false}"), @bar)
    end

    test "near miss: an attr before the spread keeps its value" do
      assert Guards.excluded?([flag: :truthy], site("flag={false} {@rest}"), @bar)
    end

    test "an omitted attr takes the component's literal default" do
      assert Guards.holds?([{:guards, [filtering?: :truthy]}], site(""), @bar)
      assert Guards.excluded?([toggle?: :truthy], site(""), @bar)
      refute Guards.excluded?([filtering?: :truthy], site(""), @bar)
    end

    test "an omitted attr without a readable default is unknown" do
      for callee <- [
            {:function, GuardedComponents, :undeclared},
            {:function, NotCompiled.Components, :bar},
            {:live_component, GuardedComponents}
          ] do
        refute Guards.holds?([{:guards, [toggle?: :falsy]}], site(""), callee)
        refute Guards.excluded?([toggle?: :truthy], site(""), callee)
      end
    end

    test "an opaque condition never holds" do
      refute Guards.holds?([{:guards, [flag: :truthy]}, :opaque], site("flag={true}"), @bar)
    end

    test "no conditions hold at every call site" do
      assert Guards.holds?([], site(""), @bar)
    end
  end
end
