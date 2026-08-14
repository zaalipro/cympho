defmodule CymphoWeb.CompanyControllerTest do
  use CymphoWeb.ConnCase, async: true

  alias Cympho.Companies

  test "regular members cannot export a company", %{conn: conn} do
    {conn, _user, company} = register_and_log_in_user(conn, %{role: "member"})

    conn = get(conn, ~p"/api/companies/#{company.id}/export")

    assert %{"errors" => [%{"detail" => "Forbidden"}]} = json_response(conn, 403)
  end

  test "company admins can export a company", %{conn: conn} do
    {conn, _user, company} = register_and_log_in_user(conn, %{role: "admin"})

    conn = get(conn, ~p"/api/companies/#{company.id}/export")

    assert %{"data" => %{"company" => %{"id" => company_id}}} = json_response(conn, 200)
    assert company_id == company.id
  end

  test "board members can export a company", %{conn: conn} do
    {conn, _user, company} =
      register_and_log_in_user(conn, %{role: "member", is_board_member: true})

    conn = get(conn, ~p"/api/companies/#{company.id}/export")

    assert %{"data" => %{"company" => %{"id" => company_id}}} = json_response(conn, 200)
    assert company_id == company.id
  end

  test "query company_id cannot authorize PUT of another company", %{conn: conn} do
    {conn, _user, company_a} = register_and_log_in_user(conn, %{role: "member"})
    company_b = other_company()
    original_name = company_b.name

    conn =
      put(conn, "/api/companies/#{company_b.id}?company_id=#{company_a.id}", %{
        "company" => %{"name" => "Hacked"}
      })

    assert %{"errors" => [%{"detail" => "Not found"}]} = json_response(conn, 404)
    assert Companies.get_company!(company_b.id).name == original_name
  end

  test "query company_id cannot authorize DELETE of another company", %{conn: conn} do
    {conn, _user, company_a} = register_and_log_in_user(conn, %{role: "member"})
    company_b = other_company()

    conn = delete(conn, "/api/companies/#{company_b.id}?company_id=#{company_a.id}")

    assert %{"errors" => [%{"detail" => "Not found"}]} = json_response(conn, 404)
    assert Companies.get_company!(company_b.id).id == company_b.id
  end

  test "generic company update does not write governance_config", %{conn: conn} do
    {_conn, _user, company} = register_and_log_in_user(conn, %{role: "admin"})
    original = company.governance_config || %{}

    assert {:ok, updated} =
             Companies.update_company(company, %{
               name: "Renamed Co",
               governance_config: %{"threshold_type" => "any"},
               status: "paused",
               budget_monthly_cents: 1,
               spent_monthly_cents: 2,
               issue_counter: 99
             })

    assert updated.name == "Renamed Co"
    assert updated.governance_config == original
    assert updated.status == company.status
    assert updated.budget_monthly_cents == company.budget_monthly_cents
    assert updated.spent_monthly_cents == company.spent_monthly_cents
    assert updated.issue_counter == company.issue_counter
  end

  defp other_company do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Other Co #{unique}",
        slug: "other-co-#{unique}"
      })

    company
  end
end
