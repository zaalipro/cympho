defmodule CymphoWeb.SearchLiveTest do
  use CymphoWeb.LiveCase, async: true

  alias Cympho.Companies
  alias Cympho.Goals
  alias Cympho.Issues
  alias Cympho.Projects

  describe "Search page" do
    test "renders company-scoped results and scoped filter options", %{
      conn: conn,
      current_company: company
    } do
      unique = System.unique_integer([:positive])
      needle = "livefind#{unique}"

      {:ok, project} =
        Projects.create_project(%{
          name: "#{needle} project",
          prefix: unique_prefix(),
          company_id: company.id
        })

      {:ok, goal} =
        Goals.create_goal(%{
          title: "#{needle} goal",
          company_id: company.id,
          project_id: project.id,
          goal_type: :mission
        })

      {:ok, _issue} =
        Issues.create_issue(%{
          title: "#{needle} current issue",
          description: "Current company search result",
          company_id: company.id,
          project_id: project.id,
          goal_id: goal.id,
          status: :todo
        })

      {:ok, foreign_company} =
        Companies.create_company(%{
          name: "Foreign Search Live #{unique}",
          slug: "foreign-search-live-#{unique}"
        })

      {:ok, _foreign_issue} =
        Issues.create_issue(%{
          title: "#{needle} foreign issue",
          description: "Should not appear in the current company search.",
          company_id: foreign_company.id,
          status: :todo
        })

      {:ok, _view, html} = live(conn, "/search?q=#{needle}")

      assert html =~ "Find company work"
      assert html =~ "Filters"
      assert html =~ "Results"
      assert html =~ "#{needle} current issue"
      assert html =~ "#{needle} project"
      assert html =~ "#{needle} goal"
      assert html =~ ~s(name="filter[goal_id]")
      refute html =~ "#{needle} foreign issue"

      {:ok, _view, issue_tab_html} = live(conn, "/search?q=#{needle}&tab=issues")

      assert issue_tab_html =~ "1 issue match for &quot;#{needle}&quot;"
    end
  end

  defp unique_prefix do
    unique = System.unique_integer([:positive])

    letters =
      0..5
      |> Enum.map(fn shift ->
        divisor = round(:math.pow(26, shift))
        <<?A + rem(div(unique, divisor), 26)>>
      end)
      |> Enum.join()

    "L" <> letters
  end
end
