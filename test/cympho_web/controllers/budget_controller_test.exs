defmodule CymphoWeb.BudgetControllerTest do
  use CymphoWeb.ConnCase, async: true

  import Ecto.Query

  alias Cympho.{Agents, Budgets, Companies, Repo}
  alias Cympho.Budgets.Budget

  setup %{conn: conn} do
    {conn, _user, company} = register_and_log_in_user(conn, %{is_board_member: true})
    other_company = company_fixture()

    {:ok, agent} = agent_fixture(company)
    {:ok, other_agent} = agent_fixture(other_company)

    %{
      conn: conn,
      company: company,
      agent: agent,
      other_company: other_company,
      other_agent: other_agent
    }
  end

  test "create cannot target an agent from another company", %{
    conn: conn,
    company: company,
    other_company: other_company,
    other_agent: other_agent
  } do
    conn =
      post(conn, ~p"/api/budgets", %{
        "budget" => %{
          "company_id" => other_company.id,
          "name" => "Injected hard stop",
          "scope_type" => "agent",
          "scope_id" => other_agent.id,
          "limit_amount" => "1.00",
          "spent_amount" => "1.00"
        }
      })

    assert %{"errors" => %{"scope_id" => ["is not in this company"]}} =
             json_response(conn, 422)

    refute Repo.exists?(from b in Budget, where: b.company_id == ^company.id)
  end

  test "create and update return nonempty budgets without Ecto internals", %{
    conn: conn,
    company: company
  } do
    create =
      post(conn, ~p"/api/budgets", %{
        "budget" => %{
          "name" => "API company cap",
          "scope_type" => "company",
          "limit_amount" => "42.50",
          "currency" => "USD"
        }
      })

    assert %{
             "data" => %{
               "id" => budget_id,
               "name" => "API company cap",
               "company_id" => company_id,
               "scope_type" => "company",
               "limit_amount" => "42.50"
             }
           } = json_response(create, 201)

    assert company_id == company.id
    refute create.resp_body =~ "__meta__"
    refute create.resp_body =~ "NotLoaded"

    update =
      patch(recycle(conn), ~p"/api/budgets/#{budget_id}", %{
        "budget" => %{"name" => "Updated company cap", "limit_amount" => "50.00"}
      })

    assert %{
             "data" => %{
               "id" => ^budget_id,
               "name" => "Updated company cap",
               "limit_amount" => "50.00"
             }
           } =
             json_response(update, 200)

    refute update.resp_body =~ "__meta__"
  end

  test "existing read actions project nonempty budgets without associations", %{
    conn: conn,
    company: company
  } do
    {:ok, budget} =
      Budgets.create_budget(%{
        company_id: company.id,
        name: "Readable company cap",
        scope_type: "company",
        scope_id: company.id,
        limit_amount: Decimal.new("12.00")
      })

    conn = Plug.Conn.assign(conn, :current_company, company)
    list = CymphoWeb.BudgetController.index(conn, %{})

    assert %{"data" => [%{"id" => id, "name" => "Readable company cap"}]} =
             json_response(list, 200)

    assert id == budget.id

    show =
      conn
      |> recycle()
      |> Plug.Conn.assign(:current_company, company)
      |> CymphoWeb.BudgetController.show(%{"id" => budget.id})

    assert %{"data" => %{"id" => ^id, "limit_amount" => "12.00"}} =
             json_response(show, 200)
  end

  test "update cannot retarget a current-company budget to another company's agent", %{
    conn: conn,
    company: company,
    agent: agent,
    other_company: other_company,
    other_agent: other_agent
  } do
    {:ok, budget} =
      Budgets.create_budget(%{
        company_id: company.id,
        name: "Original agent cap",
        scope_type: "agent",
        scope_id: agent.id,
        limit_amount: Decimal.new("10.00")
      })

    conn =
      patch(conn, ~p"/api/budgets/#{budget.id}", %{
        "budget" => %{
          "company_id" => other_company.id,
          "scope_id" => other_agent.id
        }
      })

    assert %{"errors" => %{"scope_id" => ["is not in this company"]}} =
             json_response(conn, 422)

    persisted = Repo.reload!(budget)
    assert persisted.company_id == company.id
    assert persisted.scope_id == agent.id
    assert persisted.agent_id == agent.id
  end

  test "a member board user can delete a budget through the dedicated board gate", %{
    conn: setup_conn
  } do
    {conn, _user, company} =
      register_and_log_in_user(setup_conn, %{role: "member", is_board_member: true})

    {:ok, budget} =
      Budgets.execute_budget_creation(%{
        company_id: company.id,
        name: "Board-managed cap",
        scope_type: "company",
        scope_id: company.id,
        limit_amount: Decimal.new("10.00")
      })

    assert conn |> delete(~p"/api/budgets/#{budget.id}") |> response(204)
    assert {:error, :not_found} = Budgets.get_company_budget(company.id, budget.id)
  end

  test "a viewer cannot delete a budget even with a board flag", %{conn: setup_conn} do
    {conn, _user, company} =
      register_and_log_in_user(setup_conn, %{role: "viewer", is_board_member: true})

    {:ok, budget} =
      Budgets.execute_budget_creation(%{
        company_id: company.id,
        name: "Viewer-protected cap",
        scope_type: "company",
        scope_id: company.id,
        limit_amount: Decimal.new("10.00")
      })

    assert conn |> delete(~p"/api/budgets/#{budget.id}") |> json_response(403)
    assert {:ok, _budget} = Budgets.get_company_budget(company.id, budget.id)
  end

  defp company_fixture do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Budget API Other #{unique}",
        slug: "budget-api-other-#{unique}"
      })

    company
  end

  defp agent_fixture(company) do
    unique = System.unique_integer([:positive])

    Agents.create_agent(%{
      company_id: company.id,
      name: "Budget API Agent #{unique}",
      role: :engineer,
      status: :idle,
      url_key: "budget-api-agent-#{unique}"
    })
  end
end
