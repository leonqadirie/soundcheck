defmodule Soundcheck.Heex.Template do
  @moduledoc false
  # A parsed HEEx template: a `.heex` file or one `~H` sigil.
  #
  # `id` is `{file, start}`, where `start` is the file position of the
  # template's first byte. `owner` is the `{module, function}` that renders
  # it when known. `errors` lists the syntax problems the parser recovered
  # from; the tree in `root` is usable either way.

  alias Soundcheck.Heex.Node

  @enforce_keys [:id, :file, :origin, :root]
  defstruct [:id, :file, :origin, :owner, :root, errors: []]

  @type t :: %__MODULE__{
          id: {Path.t(), Soundcheck.Span.position()},
          file: Path.t(),
          origin: :sigil | :file,
          owner: {module(), atom()} | nil,
          root: [Node.t()],
          errors: [Node.Error.t()]
        }
end
