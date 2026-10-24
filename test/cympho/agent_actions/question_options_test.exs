defmodule Cympho.AgentActions.QuestionOptionsTest do
  @moduledoc """
  B3: an agent's question may carry 2–4 short numbered answers. The parser keeps
  them only in that shape; any other shape drops the options and keeps the
  question, so a malformed option list never rejects the action.
  """
  use Cympho.DataCase, async: true

  alias Cympho.AgentActions

  defp parse_questions(questions) do
    block = """
    ```cympho-actions
    #{Jason.encode!(%{"actions" => [%{"type" => "ask_user_questions", "questions" => questions}]})}
    ```
    """

    {:ok, [%{"questions" => parsed}]} = AgentActions.parse(block)
    parsed
  end

  @question "When a customer's card payment fails, what should happen first?"

  test "keeps 2 to 4 options with the question" do
    options = [
      "Retry automatically after 3 days",
      "Email the customer first",
      "Both: email now, retry in 3 days"
    ]

    assert [%{"question" => @question, "options" => ^options}] =
             parse_questions([%{"question" => @question, "options" => options}])

    assert [%{"options" => ["Yes", "No"]}] =
             parse_questions([%{"question" => @question, "options" => ["Yes", "No"]}])

    four = ["One", "Two", "Three", "Four"]

    assert [%{"options" => ^four}] =
             parse_questions([%{"question" => @question, "options" => four}])
  end

  test "trims each option" do
    assert [%{"options" => ["Retry", "Email first"]}] =
             parse_questions([
               %{"question" => @question, "options" => ["  Retry ", "Email first\n"]}
             ])
  end

  test "drops options outside 2 to 4 and keeps the question" do
    for options <- [[], ["Only one"], ["1", "2", "3", "4", "5"]] do
      assert [%{"question" => @question} = parsed] =
               parse_questions([%{"question" => @question, "options" => options}])

      refute Map.has_key?(parsed, "options")
    end
  end

  test "drops options with a blank, non-string or over-long answer" do
    long = String.duplicate("a", 121)

    for options <- [["Retry", "   "], ["Retry", 3], ["Retry", %{"label" => "x"}], ["Retry", long]] do
      assert [%{"question" => @question} = parsed] =
               parse_questions([%{"question" => @question, "options" => options}])

      refute Map.has_key?(parsed, "options")
    end

    assert [%{"options" => [_, at_limit]}] =
             parse_questions([
               %{"question" => @question, "options" => ["Retry", String.duplicate("a", 120)]}
             ])

    assert String.length(at_limit) == 120
  end

  test "drops a non-list options value and other unknown keys" do
    assert [parsed] =
             parse_questions([
               %{"question" => @question, "options" => "Retry or email", "label" => "x"}
             ])

    assert parsed == %{"question" => @question}
  end

  test "a question without options is unchanged" do
    assert [%{"question" => @question} = parsed] = parse_questions([%{"question" => @question}])
    refute Map.has_key?(parsed, "options")
  end
end
