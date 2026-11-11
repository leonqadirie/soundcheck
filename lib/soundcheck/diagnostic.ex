defmodule Soundcheck.Diagnostic do
  @moduledoc false
  # A soundcheck finding with every location it involves.
  #
  # Credo receives a single-location projection anchored at `anchor`, a span
  # in a Credo-loaded `.ex` file. A finding located only in JavaScript has no
  # anchor; Credo reports it against the JavaScript file without a line
  # number. `mix soundcheck` and SARIF output render `primary` and `related`
  # in full.

  alias Soundcheck.Span

  @enforce_keys [:rule, :id, :message, :primary, :anchor]
  defstruct [
    :rule,
    :id,
    :message,
    :primary,
    :anchor,
    :suggestion,
    :fingerprint,
    related: [],
    resolution: :resolved,
    confidence: :high
  ]

  @typedoc """
  Why an analysis could not resolve a finding. `mix soundcheck` prints the
  reason in every output format, so the set is part of its interface.

    * `:dynamic_event`, `:dynamic_target` - the event or `phx-target` is
      not a literal, or an attr forwards it further than the analysis
      follows.
    * `:css_selector` - `phx-target` names a CSS selector.
    * `:myself_outside_component` - `phx-target={@myself}` in a
      LiveView's own render, where no LiveComponent receives it.
    * `:self_el_in_function_component` - a hook's `pushEventTo(this.el)`
      from an element in a function component, which renders inside
      several roots.
    * `:no_render_path` - no LiveView is known to render the template.
    * `:not_loadable` - the module that owns the template cannot be loaded.
    * `:unreadable_receiver` - a receiving module carries no readable
      debug info, so its handlers cannot be listed.
    * `:guarded` - the event reaches a receiver that lacks it only from
      inside conditions soundcheck cannot evaluate, such as
      `:if={@user.role == :admin}`, while another receiver handles it.
    * `:open_handlers`, `:attach_hook` - an `attach_hook/4` call in the
      receiver or its `on_mount` hooks may add handlers soundcheck cannot
      list.
    * `:hook_module_unreadable`, `:unreadable_on_mount` - an `on_mount`
      hook module cannot be read.
    * `:open_handle_params` - `handle_params/3` may set the assign.
    * `:no_live_socket` - the JavaScript sources construct no
      `LiveSocket`.
    * `:open_hook_registry` - the `LiveSocket` registers hooks soundcheck
      cannot follow, such as hooks imported from an npm package.
  """
  # `new/4` rejects any other reason: Dialyzer does not check atoms inside
  # tuples against a spec, so the type alone would not catch a misspelling.
  @reasons [
    :dynamic_event,
    :dynamic_target,
    :css_selector,
    :myself_outside_component,
    :self_el_in_function_component,
    :no_render_path,
    :not_loadable,
    :unreadable_receiver,
    :guarded,
    :open_handlers,
    :attach_hook,
    :hook_module_unreadable,
    :unreadable_on_mount,
    :open_handle_params,
    :no_live_socket,
    :open_hook_registry
  ]

  @type reason :: unquote(Enum.reduce(Enum.reverse(@reasons), &{:|, [], [&1, &2]}))

  @type unverifiable :: {:unverifiable, reason()}

  @typedoc "An analysis step's answer: a value, or why it has none."
  @type resolved(value) :: {:ok, value} | unverifiable()

  @type resolution :: :resolved | unverifiable()
  @type confidence :: :high | :medium | :low

  @type t :: %__MODULE__{
          rule: module(),
          id: String.t(),
          message: String.t(),
          primary: Span.t(),
          anchor: Span.t() | nil,
          suggestion: String.t() | nil,
          fingerprint: String.t() | nil,
          related: [{Span.t(), label :: String.t()}],
          resolution: resolution(),
          confidence: confidence()
        }

  @doc """
  Builds `rule`'s diagnostic at `primary`. The rule supplies `id` and
  `confidence`; `anchor` defaults to `primary`. `fields` sets any other
  field. Raises on unknown keys and on an unverifiable reason outside
  `t:reason/0`.
  """
  @spec new(module(), Span.t(), String.t(), keyword()) :: t()
  def new(rule, %Span{} = primary, message, fields \\ []) do
    defaults = [
      rule: rule,
      id: rule.id(),
      confidence: rule.confidence(),
      message: message,
      primary: primary,
      anchor: primary
    ]

    diagnostic = struct!(__MODULE__, Keyword.merge(defaults, fields))

    case diagnostic.resolution do
      {:unverifiable, reason} when reason not in @reasons ->
        raise ArgumentError, "unknown unverifiable reason: #{inspect(reason)}"

      _resolution ->
        diagnostic
    end
  end

  @doc """
  Drops duplicate diagnostics and sorts the rest by primary location. The
  Credo adapter and `mix soundcheck` apply it to every rule's result, so
  rules return diagnostics in any order.
  """
  @spec normalize([t()]) :: [t()]
  def normalize(diagnostics) do
    diagnostics
    |> Enum.uniq()
    |> Enum.sort_by(&{&1.primary.file, &1.primary.start})
  end

  @doc "Returns `true` when the analysis could not resolve this finding."
  @spec unverifiable?(t()) :: boolean()
  def unverifiable?(%__MODULE__{resolution: {:unverifiable, _reason}}), do: true
  def unverifiable?(%__MODULE__{}), do: false
end
