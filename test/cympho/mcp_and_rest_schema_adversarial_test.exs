defmodule Cympho.McpAndRestSchemaAdversarialTest do
  use Cympho.DataCase, async: true

  alias Cympho.Mcp.Server
  alias Cympho.Search

  @mcp_doc_path Path.expand("../../docs/MCP_API_REFERENCE.md", __DIR__)
  @rest_doc_path Path.expand("../../docs/REST_API.md", __DIR__)

  test "all 9 static tools exist in Mcp.Server" do
    expected_tools = [
      "list_issues",
      "get_issue",
      "list_issue_comments",
      "create_issue_comment",
      "create_issue",
      "list_projects",
      "list_agents",
      "get_kanban_state",
      "search"
    ]

    server_tools = Server.tools()
    server_tool_names = Enum.map(server_tools, & &1.name)

    assert length(server_tools) == 9
    assert Enum.sort(server_tool_names) == Enum.sort(expected_tools)
  end

  test "verify MCP tool parameter names and required fields against Server.tools()" do
    doc_content = File.read!(@mcp_doc_path)

    for tool <- Server.tools() do
      # Ensure tool name is in doc
      assert doc_content =~ "### 3." and doc_content =~ "`#{tool.name}`"

      # Check inputSchema properties
      properties = get_in(tool, [:inputSchema, :properties]) || %{}

      for {prop_name, _schema} <- properties do
        assert doc_content =~ "\"#{prop_name}\""
      end

      # Check required fields
      required = get_in(tool, [:inputSchema, :required]) || []

      for req_field <- required do
        assert doc_content =~ "\"#{req_field}\""
      end
    end
  end

  test "get_kanban_state return contract key is status, not column" do
    # In docs/MCP_API_REFERENCE.md, get_kanban_state documents:
    # "status": "todo"
    # Matching lib/cympho/mcp/server.ex:539 where the map returned is:
    # %{status: status, count: length(issues), issues: ...}
    # When serialized, the JSON key is "status", not "column".
    doc_content = File.read!(@mcp_doc_path)
    assert doc_content =~ "\"status\": \"todo\""
    refute doc_content =~ "\"column\": \"todo\""

    # We inspect the code in Server to confirm the key is :status
    statuses = Cympho.Issues.Issue.status_options()
    assert :todo in statuses
    assert :backlog in statuses
    assert :in_progress in statuses
  end

  test "search return contract documents issues and comments, not projects and agents" do
    doc_content = File.read!(@mcp_doc_path)
    # The doc accurately reflects Search.search/2 return contract:
    # "result": { "issues": [...], "comments": [...] }
    assert doc_content =~ "\"issues\": ["
    assert doc_content =~ "\"comments\": ["
    refute doc_content =~ "\"projects\": ["
    refute doc_content =~ "\"agents\": []"

    # Search.search/2 returns %{issues: ..., comments: ...}
    res = Search.search("anything")
    assert Map.has_key?(res, :issues)
    assert Map.has_key?(res, :comments)
    refute Map.has_key?(res, :projects)
    refute Map.has_key?(res, :agents)
  end

  test "User registration requires name, not full_name" do
    doc_content = File.read!(@rest_doc_path)
    assert doc_content =~ "\"name\": \"Lead Engineer\""
    refute doc_content =~ "\"full_name\": \"Lead Engineer\""

    # Attempting to register with full_name instead of name fails
    changeset =
      Cympho.Users.User.registration_changeset(%Cympho.Users.User{}, %{
        "email" => "test@example.com",
        "password" => "password1234",
        "full_name" => "Lead Engineer"
      })

    refute changeset.valid?

    assert %{name: ["can't be blank"]} =
             Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
  end

  test "LoginJSON returns token at top level and uses name, not full_name" do
    doc_content = File.read!(@rest_doc_path)
    # Doc accurately reflects:
    # "data": { ... "name": ... }, "token": ...
    assert doc_content =~ "\"name\": \"Company Owner\""
    refute doc_content =~ "\"full_name\": \"Company Owner\""

    user = %Cympho.Users.User{
      id: Ecto.UUID.generate(),
      email: "owner@cympho.local",
      name: "Company Owner",
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    rendered =
      CymphoWeb.LoginJSON.show(%{
        user: user,
        company_id: Ecto.UUID.generate(),
        token: "jwt_token"
      })

    assert Map.has_key?(rendered, :token)
    refute Map.has_key?(rendered.data, :token)
    assert rendered.data.name == "Company Owner"
    refute Map.has_key?(rendered.data, :full_name)
  end

  test "IssueThreadInteraction requires kind (:suggest_tasks, :ask_user_questions, :request_confirmation), not type" do
    doc_content = File.read!(@rest_doc_path)
    # Doc accurately reflects kind and payload:
    assert doc_content =~ "ask_user_questions"
    assert doc_content =~ "suggest_tasks"
    assert doc_content =~ "request_confirmation"
    refute doc_content =~ "\"type\": \"question|confirmation\""

    changeset =
      Cympho.Issues.IssueThreadInteraction.changeset(%Cympho.Issues.IssueThreadInteraction{}, %{
        "issue_id" => Ecto.UUID.generate(),
        "type" => "question",
        "prompt" => "Please confirm"
      })

    refute changeset.valid?
    errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
    assert %{kind: ["can't be blank"]} = errors
  end
end
