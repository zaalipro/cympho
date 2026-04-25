defmodule Cympho.CommentsParserTest do
  use ExUnit.Case, async: true
  alias Cympho.Comments.Parser

  describe "extract_mentions" do
    test "extracts @-mentions from text" do
      text = "Hey @alice and @bob-dev, can you review?"
      assert Parser.extract_mentions(text) == ["alice", "bob-dev"]
    end

    test "deduplicates mentions" do
      text = "@alice mentioned @alice again"
      assert Parser.extract_mentions(text) == ["alice"]
    end

    test "returns empty list for no mentions" do
      assert Parser.extract_mentions("no mentions here") == []
    end

    test "handles nil input" do
      assert Parser.extract_mentions(nil) == []
    end
  end

  describe "extract_issue_refs" do
    test "extracts issue references like PREFIX-123" do
      text = "Blocked by CYM-42 and CYM-99"
      refs = Parser.extract_issue_refs(text)
      assert length(refs) == 2
      assert Enum.at(refs, 0).prefix == "CYM"
      assert Enum.at(refs, 0).seq == 42
      assert Enum.at(refs, 0).ref == "CYM-42"
    end

    test "deduplicates identical refs" do
      text = "See CYM-10 and also CYM-10"
      refs = Parser.extract_issue_refs(text)
      assert length(refs) == 1
    end

    test "returns empty list for no refs" do
      assert Parser.extract_issue_refs("no refs") == []
    end

    test "handles nil input" do
      assert Parser.extract_issue_refs(nil) == []
    end
  end
end
