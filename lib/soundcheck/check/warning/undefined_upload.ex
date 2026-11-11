defmodule Soundcheck.Check.Warning.UndefinedUpload do
  use Soundcheck.Check,
    id: "SC804",
    base_priority: :high,
    category: :warning,
    confidence: :medium,
    tier: :syntactic,
    default: false,
    summary:
      "`@uploads.name` reads and `consume_uploaded_entries` and other upload calls on names the module never allows",
    explanations: [
      check: """
      Flags upload names a LiveView or LiveComponent uses but never allows.
      `@uploads` holds only the uploads `allow_upload/3` registered, so a
      template reading `@uploads.photo` when the module allows `:avatar`
      raises `KeyError` on render, and `consume_uploaded_entries/3`,
      `uploaded_entries/2`, `cancel_upload/3`, or `disallow_upload/2` on an
      unknown name raises `ArgumentError`.

      Before:

          def mount(_params, _session, socket),
            do: {:ok, allow_upload(socket, :avatar, accept: ~w(.jpg .png))}

          <.live_file_input upload={@uploads.photo} />

      After:

          <.live_file_input upload={@uploads.avatar} />

      Definitions are `allow_upload/3` calls with a literal atom name in the
      module's own functions and in the project functions it calls, through
      remote calls and imports at any depth. Reads come from its `render/1`
      template, colocated or inline. The check skips a module when it and
      those functions allow no upload, when any of them names one
      dynamically, or when it passes its socket to a function outside the
      project and Phoenix, since that function may allow uploads the check
      cannot see.
      """
    ]

  alias Soundcheck.Analysis.SocketNames
  alias Soundcheck.Diagnostic
  alias Soundcheck.Graph

  @uploads %{
    assign: :uploads,
    defining: [:allow_upload],
    using: [:consume_uploaded_entries, :uploaded_entries, :cancel_upload, :disallow_upload]
  }

  @impl Soundcheck.Rule
  def analyze(%Graph{} = graph, _params) do
    for %{entry: entry, name: name, defined: defined, span: span, anchor: anchor} <-
          SocketNames.undefined(graph, @uploads) do
      Diagnostic.new(
        __MODULE__,
        span,
        "`#{inspect(entry.name)}` uses the upload #{inspect(name)} but allows only " <>
          "#{Enum.map_join(defined, ", ", &inspect/1)}, so LiveView raises.",
        suggestion: SocketNames.suggestion(name, defined),
        anchor: anchor
      )
    end
  end
end
