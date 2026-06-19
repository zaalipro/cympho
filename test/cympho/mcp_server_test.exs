defmodule Cympho.Mcp.ServerTest do
  use Cympho.DataCase, async: true

  alias Cympho.Agents
  alias Cympho.Comments
  alias Cympho.Companies
  alias Cympho.Issues
  alias Cympho.Mcp.Server

  describe "tools/0" do
    test "documents routed issue intake fields" do
      create_issue = Enum.find(Server.tools(), &(&1.name == "create_issue"))

      assert get_in(create_issue, [:inputSchema, :properties, :assigned_role])
      assert get_in(create_issue, [:inputSchema, :properties, :assignee_id])
    end

    test "documents issue comment tools" do
      list_comments = Enum.find(Server.tools(), &(&1.name == "list_issue_comments"))
      create_comment = Enum.find(Server.tools(), &(&1.name == "create_issue_comment"))

      assert get_in(list_comments, [:inputSchema, :properties, :issue_id])
      assert get_in(list_comments, [:inputSchema, :properties, :limit])
      assert get_in(create_comment, [:inputSchema, :properties, :issue_id])
      assert get_in(create_comment, [:inputSchema, :properties, :body])
    end
  end

  describe "call_tool/3 create_issue" do
    setup do
      {:ok, company} = Companies.create_company(%{name: "MCP Co", slug: unique_slug("mcp")})

      {:ok, other_company} =
        Companies.create_company(%{name: "Other Co", slug: unique_slug("other")})

      {:ok, bridge} =
        Agents.create_agent(%{
          company_id: company.id,
          name: "MCP Bridge",
          role: :cto,
          status: :idle
        })

      {:ok, ceo} =
        Agents.create_agent(%{
          company_id: company.id,
          name: "CEO",
          role: :ceo,
          status: :idle
        })

      {:ok, other_ceo} =
        Agents.create_agent(%{
          company_id: other_company.id,
          name: "Other CEO",
          role: :ceo,
          status: :idle
        })

      {:ok,
       company: company,
       other_company: other_company,
       bridge: bridge,
       ceo: ceo,
       other_ceo: other_ceo}
    end

    test "creates a company-scoped issue routed to the requested CEO", %{
      bridge: bridge,
      ceo: ceo
    } do
      result =
        Server.call_tool(
          "create_issue",
          %{
            "title" => "Define owner plan",
            "description" => "Owner wants the CEO to choose the first execution plan.",
            "priority" => "high",
            "assigned_role" => "ceo",
            "assignee_id" => ceo.id
          },
          bridge
        )

      assert %{success: true, issue: %{id: issue_id, assigned_role: "ceo"}} = result
      assert result.issue.assignee_id == ceo.id

      issue = Issues.get_issue!(issue_id)
      assert issue.company_id == bridge.company_id
      assert issue.assignee_id == ceo.id
      assert issue.assigned_role == "ceo"
      assert issue.origin_type == "mcp"
      assert issue.origin_id == bridge.id
      assert issue.created_by_agent_id == bridge.id
    end

    test "rejects assignees from another company", %{bridge: bridge, other_ceo: other_ceo} do
      result =
        Server.call_tool(
          "create_issue",
          %{
            "title" => "Cross-company issue",
            "assigned_role" => "ceo",
            "assignee_id" => other_ceo.id
          },
          bridge
        )

      assert result == %{
               success: false,
               errors: %{assignee_id: ["does not belong to this company"]}
             }
    end

    test "rejects role and assignee mismatches", %{bridge: bridge} do
      result =
        Server.call_tool(
          "create_issue",
          %{
            "title" => "Wrong role issue",
            "assigned_role" => "ceo",
            "assignee_id" => bridge.id
          },
          bridge
        )

      assert result == %{
               success: false,
               errors: %{assignee_id: ["has role cto and cannot be assigned as ceo"]}
             }
    end

    test "filters list_issues by assigned role", %{bridge: bridge, company: company, ceo: ceo} do
      {:ok, _ceo_issue} =
        Issues.create_issue(%{
          company_id: company.id,
          title: "CEO-only",
          assigned_role: "ceo",
          assignee_id: ceo.id,
          skip_auto_assign: true
        })

      {:ok, _cto_issue} =
        Issues.create_issue(%{
          company_id: company.id,
          title: "CTO-only",
          assigned_role: "cto",
          assignee_id: bridge.id,
          skip_auto_assign: true
        })

      result = Server.call_tool("list_issues", %{"assigned_role" => "ceo"}, bridge)

      assert result.total == 1
      assert [%{title: "CEO-only", assigned_role: "ceo"}] = result.issues
    end

    test "get_issue includes recent comments", %{bridge: bridge, company: company} do
      {:ok, issue} =
        Issues.create_issue(%{
          company_id: company.id,
          title: "Trace external handoff",
          skip_auto_assign: true
        })

      {:ok, _comment} =
        Comments.create_comment(%{
          issue_id: issue.id,
          body: "CTO synthesis is ready for CEO handoff.",
          author_type: "system",
          author_id: "swarm"
        })

      result = Server.call_tool("get_issue", %{"issue_id" => issue.id}, bridge)

      assert result.comments_count == 1

      assert [
               %{
                 body: "CTO synthesis is ready for CEO handoff.",
                 author_type: "system",
                 author_id: "swarm"
               }
             ] = result.comments
    end

    test "lists issue comments with a bounded limit", %{bridge: bridge, company: company} do
      {:ok, issue} =
        Issues.create_issue(%{
          company_id: company.id,
          title: "Readable agent trace",
          skip_auto_assign: true
        })

      {:ok, _first} =
        Comments.create_comment(%{
          issue_id: issue.id,
          body: "Worker note",
          author_type: "agent",
          author_id: bridge.id
        })

      {:ok, _second} =
        Comments.create_comment(%{
          issue_id: issue.id,
          body: "CTO synthesis",
          author_type: "system",
          author_id: "cto"
        })

      result =
        Server.call_tool("list_issue_comments", %{"issue_id" => issue.id, "limit" => 1}, bridge)

      assert result.total == 2
      assert result.limit == 1
      assert length(result.comments) == 1
    end

    test "creates an agent-authored issue comment", %{bridge: bridge, company: company} do
      {:ok, issue} =
        Issues.create_issue(%{
          company_id: company.id,
          title: "Append delivery evidence",
          skip_auto_assign: true
        })

      result =
        Server.call_tool(
          "create_issue_comment",
          %{"issue_id" => issue.id, "body" => "  Worker result captured.  "},
          bridge
        )

      assert %{success: true, comment: %{body: "Worker result captured.", author_type: "agent"}} =
               result

      assert result.comment.author_id == bridge.id

      assert [%{body: "Worker result captured.", author_type: "agent", author_id: author_id}] =
               Comments.list_comments(issue.id)

      assert author_id == bridge.id
    end

    test "rejects blank MCP comments", %{bridge: bridge, company: company} do
      {:ok, issue} =
        Issues.create_issue(%{
          company_id: company.id,
          title: "Blank comment guard",
          skip_auto_assign: true
        })

      result =
        Server.call_tool(
          "create_issue_comment",
          %{"issue_id" => issue.id, "body" => "  "},
          bridge
        )

      assert result == %{success: false, errors: %{body: ["can't be blank"]}}
    end

    test "comment tools are scoped to the authenticated agent company", %{
      bridge: bridge,
      other_company: other_company
    } do
      {:ok, other_issue} =
        Issues.create_issue(%{
          company_id: other_company.id,
          title: "Other tenant",
          skip_auto_assign: true
        })

      assert Server.call_tool("list_issue_comments", %{"issue_id" => other_issue.id}, bridge) ==
               %{error: "Issue not found"}

      assert Server.call_tool(
               "create_issue_comment",
               %{"issue_id" => other_issue.id, "body" => "Should not cross tenant"},
               bridge
             ) == %{error: "Issue not found"}
    end
  end

  defp unique_slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
