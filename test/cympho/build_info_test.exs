defmodule Cympho.BuildInfoTest do
  use ExUnit.Case, async: true

  alias Cympho.BuildInfo
  alias Cympho.BuildInfo.Validation

  test "embeds a version and an allowlisted revision at compile time" do
    assert {:ok, _version} = Version.parse(BuildInfo.version())
    assert BuildInfo.release().version == BuildInfo.version()
    assert BuildInfo.release().revision == BuildInfo.revision()

    assert BuildInfo.revision() in ["development", "unknown"] or
             BuildInfo.revision() =~ ~r/\A[0-9a-f]{7,64}\z/
  end

  test "accepts hexadecimal Git revisions and normalizes their case" do
    assert Validation.revision("ABCDEF1234567", :prod) == "abcdef1234567"
    assert Validation.revision(String.duplicate("a", 64), :prod) == String.duplicate("a", 64)
  end

  test "uses explicit development and unknown fallbacks for invalid revisions" do
    for invalid <- [nil, "", "abcdef", "release-1", "abcdef1 dirty", String.duplicate("a", 65)] do
      assert Validation.revision(invalid, :test) == "development"
      assert Validation.revision(invalid, :prod) == "unknown"
    end
  end

  test "accepts development identity only outside production" do
    assert Validation.identity_valid?("development", :dev)
    assert Validation.identity_valid?("development", :test)
    refute Validation.identity_valid?("development", :prod)
    refute Validation.identity_valid?("unknown", :prod)
    assert Validation.identity_valid?("ABCDEF1", :prod)
  end

  test "reports whether the embedded build identity is valid for its environment" do
    assert BuildInfo.identity_valid?() ==
             Validation.identity_valid?(BuildInfo.revision(), Mix.env())
  end
end
