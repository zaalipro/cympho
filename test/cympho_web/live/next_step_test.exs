defmodule CymphoWeb.NextStepTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias CymphoWeb.NextStep

  defp doc(html), do: Floki.parse_fragment!(html)
  defp text(doc, selector), do: doc |> Floki.find(selector) |> Floki.text() |> squish()
  defp squish(text), do: text |> String.replace(~r/\s+/u, " ") |> String.trim()

  describe "answer_from_params/1" do
    test "a chosen option is the answer" do
      assert NextStep.answer_from_params(%{"_id" => "q1", "response" => " Email first "}) ==
               {:ok, "q1", "Email first"}
    end

    test "the own row sends the written answer" do
      params = %{"_id" => "q1", "response" => "own", "own_response" => " Retry once "}
      assert NextStep.answer_from_params(params) == {:ok, "q1", "Retry once"}
    end

    test "a written answer without a chosen row is sent" do
      params = %{"_id" => "q1", "response" => "", "own_response" => "Retry once"}
      assert NextStep.answer_from_params(params) == {:ok, "q1", "Retry once"}
    end

    test "nothing chosen and nothing written is refused" do
      assert NextStep.answer_from_params(%{"_id" => "q1"}) == {:error, :empty}

      assert NextStep.answer_from_params(%{
               "_id" => "q1",
               "response" => "own",
               "own_response" => " "
             }) ==
               {:error, :empty}

      assert NextStep.answer_from_params(%{"response" => "Email first"}) == {:error, :empty}
    end
  end

  describe "the company-wide pairs" do
    test "all clear: Nothing needs you, with New task as the one primary" do
      html = render_component(&NextStep.all_clear/1, %{})
      doc = doc(html)

      assert text(doc, ".paper .eyebrow") == "All clear"
      assert text(doc, ".paper .nt") == "Nothing needs you"

      # The heading says "After you add it" once; the effect row does not repeat it.
      assert text(doc, ".ink .ink-h") == "After you add it"

      assert text(doc, ".ink .conseq li") ==
               "Cympho gives it to an agent with the right role, or keeps it in Later if nobody is free."

      assert length(String.split(Floki.text(doc), "After you add it")) == 2

      assert [primary] = Floki.find(doc, ".pw")
      assert Floki.text(primary) =~ "New task"
      assert Floki.attribute(primary, "href") == ["/issues/new"]
      assert Floki.attribute(primary, "data-quick-create-trigger") != []
    end

    test "agents off: Turn agents on, answered by a disclosure" do
      doc = doc(render_component(&NextStep.server_off_step/1, %{}))

      assert text(doc, ".paper .eyebrow") =~ "Agents off"
      assert text(doc, ".paper .nt") == "Turn agents on"
      assert text(doc, ".ink .ink-h") == "Until it changes"
      assert [summary] = Floki.find(doc, ".ink details.howto > summary.pw")
      assert Floki.text(summary) =~ "How to turn agents on"

      assert text(doc, ".ink details.howto p") ==
               "Whoever runs this server turns the orchestrator on; agents then pick up work again."
    end

    test "paused at the limit names the limit and its window" do
      spending = %{spent: Decimal.new("300"), limit: Decimal.new("300"), days: 30, percent: 100.0}
      # The fields every OwnerAttention budget item carries.
      item = %{
        kind: :budget_incident,
        event_type: "budget_exceeded",
        title: "Company budget needs immediate attention",
        summary: "Spending has reached a configured limit.",
        target_path: "/budgets",
        issue: nil,
        agent: nil,
        inserted_at: DateTime.utc_now()
      }

      doc = doc(render_component(&NextStep.pair/1, %{item: item, from: "/", spending: spending}))

      assert text(doc, ".paper .nt") == "Raise the spending limit"

      assert text(doc, ".paper .obj") ==
               "Agents stopped: the $300 limit for the last 30 days was reached."

      assert [_] = Floki.find(doc, ".paper .tk.full")
      assert text(doc, ".paper .tk-legend") == "agents stop"
    end
  end
end
