defmodule Soundcheck.Check.UndefinedUploadTest do
  use Soundcheck.CheckCase

  import Soundcheck.HeexCase, only: [text_at: 2]

  alias Soundcheck.Check.Warning.UndefinedUpload

  @fixture "test/support/fixtures/upload_names.ex"

  defp fixture, do: [{@fixture, File.read!(@fixture)}]

  test "fires on template reads and upload calls of names the module never allows" do
    diagnostics = analyze(UndefinedUpload, fixture())
    texts = Enum.map(diagnostics, &text_at(File.read!(@fixture), &1.primary))

    assert texts == ["@uploads[:photo]", "consume_uploaded_entries"]
    assert [photo, covers] = diagnostics
    assert photo.message =~ "uses the upload :photo but allows only :avatar, :cover"
    assert photo.suggestion == nil
    assert covers.suggestion == "Did you mean :cover?"
  end

  test "near miss: allowed names" do
    diagnostics = analyze(UndefinedUpload, fixture())
    refute Enum.any?(diagnostics, &(&1.message =~ "upload :avatar"))
  end
end
