defmodule Soundcheck.Heex.Node do
  @moduledoc false
  # Node structs for parsed HEEx templates.
  #
  # Every span is in absolute file coordinates (see `Soundcheck.Span`).
  # Embedded Elixir expressions carry their parsed AST, whose metadata is
  # also in file coordinates, or `{:error, reason}` when the expression does
  # not parse.

  alias Soundcheck.Span

  @type expr :: Macro.t() | {:error, term()}

  defmodule Element do
    @moduledoc false
    # A tag, component call, or slot.
    #
    # `kind` is `:html`, `:local_component` (`<.name>`), `:remote_component`
    # (`<Mod.name>`), or `:slot` (`<:name>`). `close` is `:normal`, `:self`
    # (`<x />`), `:void` (an HTML void element), or `:missing` when error
    # recovery closed the element.
    @enforce_keys [:tag, :kind, :span, :open_span]
    defstruct [:tag, :kind, :span, :open_span, attrs: [], children: [], close: :normal]

    @type t :: %__MODULE__{
            tag: String.t(),
            kind: :html | :local_component | :remote_component | :slot,
            attrs: [Soundcheck.Heex.Node.Attr.t()],
            children: [Soundcheck.Heex.Node.t()],
            span: Span.t(),
            open_span: Span.t(),
            close: :normal | :self | :void | :missing
          }
  end

  defmodule Attr do
    @moduledoc false
    # An attribute. `name` is `:root` for `{@rest}`-style attributes.
    #
    # `value` is `{:string, value, delimiter, value_span}`,
    # `{:expr, ast, source, expr_span}`, or `nil` for a bare attribute.
    @enforce_keys [:name, :span, :name_span]
    defstruct [:name, :value, :span, :name_span]

    @type value ::
            {:string, String.t(), ?" | ?', Span.t()}
            | {:expr, Soundcheck.Heex.Node.expr(), String.t(), Span.t()}
            | nil

    @type t :: %__MODULE__{
            name: String.t() | :root,
            value: value(),
            span: Span.t(),
            name_span: Span.t() | nil
          }
  end

  defmodule Text do
    @moduledoc false
    # Literal text, kept verbatim.
    @enforce_keys [:value, :span]
    defstruct [:value, :span]
    @type t :: %__MODULE__{value: String.t(), span: Span.t()}
  end

  defmodule BodyExpr do
    @moduledoc false
    # A `{expr}` interpolation in the template body.
    @enforce_keys [:ast, :source, :span]
    defstruct [:ast, :source, :span]

    @type t :: %__MODULE__{
            ast: Soundcheck.Heex.Node.expr(),
            source: String.t(),
            span: Span.t()
          }
  end

  defmodule Eex do
    @moduledoc false
    # A standalone `<%= expr %>` (marker `"="`) or `<% expr %>` (marker `""`).
    @enforce_keys [:ast, :source, :span, :marker]
    defstruct [:ast, :source, :span, :marker]

    @type t :: %__MODULE__{
            ast: Soundcheck.Heex.Node.expr(),
            source: String.t(),
            span: Span.t(),
            marker: String.t()
          }
  end

  defmodule EexBlock do
    @moduledoc false
    # An EEx block such as `<%= if @x do %>...<% else %>...<% end %>`.
    #
    # `head` holds the opening expression; its AST is parsed with a
    # synthetic `end`. Each clause holds the source of the expression that
    # opened it (the head or a middle expression such as `else` or
    # `{:ok, x} ->`), its children, and for a middle clause the AST of its
    # head without the arrow (`nil` for the first clause, whose head is the
    # block's).
    defmodule Head do
      @moduledoc false
      # The expression that opens the block.
      @enforce_keys [:ast, :source, :span]
      defstruct [:ast, :source, :span]

      @type t :: %__MODULE__{
              ast: Soundcheck.Heex.Node.expr(),
              source: String.t(),
              span: Span.t()
            }
    end

    defmodule Clause do
      @moduledoc false
      # One clause of the block and the nodes it renders.
      @enforce_keys [:source, :ast, :span, :children]
      defstruct [:source, :ast, :span, :children]

      @type t :: %__MODULE__{
              source: String.t(),
              ast: Soundcheck.Heex.Node.expr() | nil,
              span: Span.t(),
              children: [Soundcheck.Heex.Node.t()]
            }
    end

    @enforce_keys [:head, :clauses, :span, :marker]
    defstruct [:head, :clauses, :span, :marker, close: :normal]

    @type clause :: Clause.t()

    @type t :: %__MODULE__{
            head: Head.t(),
            clauses: [clause()],
            span: Span.t(),
            marker: String.t(),
            close: :normal | :missing
          }
  end

  defmodule Comment do
    @moduledoc false
    # An HTML comment (`<!-- -->`) or an EEx comment (`<%!-- --%>`, `<%# %>`).
    @enforce_keys [:value, :span, :kind]
    defstruct [:value, :span, :kind]
    @type t :: %__MODULE__{value: String.t(), span: Span.t(), kind: :html | :eex}
  end

  defmodule Error do
    @moduledoc false
    # A syntax problem the parser recovered from.
    @enforce_keys [:message, :span]
    defstruct [:message, :span]
    @type t :: %__MODULE__{message: String.t(), span: Span.t()}
  end

  @type t ::
          Element.t()
          | Text.t()
          | BodyExpr.t()
          | Eex.t()
          | EexBlock.t()
          | Comment.t()
end
