defmodule CymphoWeb.CompanyControllerTest do
  use CymphoWeb.ConnCase, async: false

  alias Cympho.Companies
  alias Cympho.Companies.ImportDecodeAdmission

  test "admin cannot grant or remove owner via membership API", %{conn: conn} do
    {conn, admin, company} = register_and_log_in_user(conn, %{role: "admin"})
    target = user("owner-target")

    denied =
      post(conn, "/api/companies/#{company.id}/members", %{user_id: target.id, role: "owner"})

    assert json_response(denied, 403)
    refute Companies.has_access?(target.id, company.id)

    owner = user("existing-owner")

    {:ok, membership} =
      Companies.create_membership(%{company_id: company.id, user_id: owner.id, role: "owner"})

    denied = conn |> recycle() |> delete("/api/companies/#{company.id}/members/#{owner.id}")
    assert json_response(denied, 403)
    assert Companies.get_membership(owner.id, company.id).id == membership.id
    assert Companies.get_membership(admin.id, company.id)
  end

  test "membership and invite JSON use allowlisted fields", %{conn: conn} do
    {conn, _owner, company} = register_and_log_in_user(conn, %{role: "owner"})
    target = user("json-target")

    added =
      post(conn, "/api/companies/#{company.id}/members", %{user_id: target.id, role: "member"})

    assert %{"data" => %{"id" => membership_id, "user_id" => user_id, "role" => "member"}} =
             json_response(added, 201)

    assert user_id == target.id
    assert is_binary(membership_id)
    assert get_in(json_response(added, 201), ["data", "user", "email"]) == target.email

    members =
      conn |> recycle() |> get("/api/companies/#{company.id}/members") |> json_response(200)

    assert Enum.any?(
             members["data"],
             &(&1["user_id"] == target.id and &1["user"]["name"] == target.name)
           )

    refute Enum.any?(members["data"], &Map.has_key?(&1, "password_hash"))
    refute Enum.any?(members["data"], &Map.has_key?(&1["user"], "password_hash"))

    created =
      conn
      |> recycle()
      |> post("/api/companies/#{company.id}/invites", %{
        invite: %{email: "invite@example.com", role: "member"}
      })

    assert %{"data" => %{"token" => token, "email" => "invite@example.com"}} =
             json_response(created, 201)

    assert is_binary(token)

    listed =
      conn |> recycle() |> get("/api/companies/#{company.id}/invites") |> json_response(200)

    assert [%{"email" => "invite@example.com"} | _] = listed["data"]
    refute Enum.any?(listed["data"], &Map.has_key?(&1, "token"))
  end

  test "join request JSON supports a nonempty read", %{conn: conn} do
    {conn, _admin, company} = register_and_log_in_user(conn, %{role: "admin"})
    target = user("join-target")

    {:ok, request} =
      Companies.create_join_request(%{
        company_id: company.id,
        user_id: target.id,
        message: "Please"
      })

    listed = conn |> get("/api/companies/#{company.id}/join-requests") |> json_response(200)
    assert Enum.any?(listed["data"], &(&1["id"] == request.id and &1["message"] == "Please"))
    assert Enum.any?(listed["data"], &(&1["user"]["email"] == target.email))
    refute Enum.any?(listed["data"], &Map.has_key?(&1["user"], "password_hash"))
  end

  test "join request creation and approval keep JSON envelopes", %{conn: conn} do
    {conn, owner, company} = register_and_log_in_user(conn, %{role: "owner"})
    target = user("new-join-target")

    created = post(conn, "/api/companies/#{company.id}/join-requests", %{message: "Please"})

    assert %{
             "data" => %{
               "user_id" => user_id,
               "message" => "Please",
               "user" => %{"email" => email}
             }
           } =
             json_response(created, 201)

    assert user_id == owner.id
    assert email == owner.email

    {:ok, request} =
      Companies.create_join_request(%{company_id: company.id, user_id: target.id})

    approved =
      conn
      |> recycle()
      |> post("/api/companies/#{company.id}/join-requests/#{request.id}/approve")

    assert %{"data" => %{"approved" => true}} = json_response(approved, 200)
    assert Companies.has_access?(target.id, company.id)
  end

  test "replayed and stale join approvals return conflicts without changing membership", %{
    conn: conn
  } do
    {conn, owner, company} = register_and_log_in_user(conn, %{role: "owner"})
    rejected_user = user("rejected-join")

    {:ok, rejected} =
      Companies.create_join_request(%{company_id: company.id, user_id: rejected_user.id})

    {:ok, _} = Companies.reject_join_request(rejected, owner.id)

    response =
      post(conn, "/api/companies/#{company.id}/join-requests/#{rejected.id}/approve")

    assert %{"error" => "Join request is no longer pending"} = json_response(response, 409)
    refute Companies.has_access?(rejected_user.id, company.id)

    existing_user = user("existing-join")

    {:ok, pending} =
      Companies.create_join_request(%{company_id: company.id, user_id: existing_user.id})

    {:ok, _} =
      Companies.create_membership_for_actor(owner.id, %{
        company_id: company.id,
        user_id: existing_user.id,
        role: "owner"
      })

    response =
      conn
      |> recycle()
      |> post("/api/companies/#{company.id}/join-requests/#{pending.id}/approve")

    assert %{"error" => "User is already a member"} = json_response(response, 409)
    assert Companies.get_role(existing_user.id, company.id) == "owner"
  end

  defp user(prefix) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Cympho.Users.create_user(%{
        name: prefix,
        email: "#{prefix}-#{unique}@example.com",
        password: "password1234"
      })

    user
  end

  test "creating a company atomically grants owner and board membership", %{conn: conn} do
    {conn, user, _company} = register_and_log_in_user(conn, %{role: "member"})
    unique = System.unique_integer([:positive])

    conn =
      post(conn, "/api/companies", %{
        "company" => %{"name" => "Created #{unique}", "slug" => "created-#{unique}"}
      })

    company_id = get_in(json_response(conn, 201), ["data", "id"])
    membership = Companies.get_membership(user.id, company_id)
    assert membership.role == "owner"
    assert membership.is_board_member
    assert Cympho.Users.get_user!(user.id).company_id == company_id
  end

  test "importing grants ownership without silently switching the default company", %{conn: conn} do
    {conn, user, source_company} =
      register_and_log_in_user(conn, %{role: "admin", is_board_member: true})

    default_company_id = Cympho.Users.get_user!(user.id).company_id

    package =
      source_company.id |> Companies.export_company() |> Jason.encode!() |> Jason.decode!()

    conn = post(conn, "/api/companies/import", %{"company" => package})

    imported_company_id = get_in(json_response(conn, 201), ["data", "id"])
    refute imported_company_id == source_company.id
    membership = Companies.get_membership(user.id, imported_company_id)
    assert membership.role == "owner"
    assert membership.is_board_member
    assert Cympho.Users.get_user!(user.id).company_id == default_company_id
  end

  test "legacy whole-body import rejects a writable non-board member", %{conn: conn} do
    {conn, _user, source_company} = register_and_log_in_user(conn, %{role: "admin"})

    package =
      source_company.id |> Companies.export_company() |> Jason.encode!() |> Jason.decode!()

    conn = post(conn, "/api/companies/import", %{"company" => package})

    assert %{"errors" => [%{"detail" => "No board members configured for this company"}]} =
             json_response(conn, 403)
  end

  test "legacy whole-body import fails fast while decoded import capacity is busy", %{conn: conn} do
    {conn, _user, source_company} =
      register_and_log_in_user(conn, %{role: "admin", is_board_member: true})

    package =
      source_company.id |> Companies.export_company() |> Jason.encode!() |> Jason.decode!()

    {:ok, token} = ImportDecodeAdmission.checkout()

    try do
      response = post(conn, "/api/companies/import", %{"company" => package})
      assert get_resp_header(response, "retry-after") == ["5"]
      assert %{"error" => "Import processing is currently busy"} = json_response(response, 429)
    after
      ImportDecodeAdmission.release(token)
    end
  end

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

  test "viewer board members cannot export a company", %{conn: conn} do
    {conn, _user, company} =
      register_and_log_in_user(conn, %{role: "viewer", is_board_member: true})

    conn = get(conn, ~p"/api/companies/#{company.id}/export")

    assert %{"errors" => [%{"detail" => "Forbidden"}]} = json_response(conn, 403)
  end

  test "a writable board member can govern a path-target company", %{conn: conn} do
    {conn, user, _current_company} = register_and_log_in_user(conn, %{role: "member"})
    target = other_company()

    {:ok, _membership} =
      Companies.create_membership(%{
        user_id: user.id,
        company_id: target.id,
        role: "member",
        is_board_member: true
      })

    conn =
      patch(conn, ~p"/api/companies/#{target.id}/governance-config", %{
        "governance_config" => %{"threshold_type" => "any"}
      })

    assert %{"data" => %{"id" => target_id}} = json_response(conn, 200)
    assert target_id == target.id
    assert Companies.get_company!(target.id).governance_config["threshold_type"] == "any"
  end

  test "a writable board member can manage a path-target company", %{conn: conn} do
    {conn, user, _current_company} = register_and_log_in_user(conn, %{role: "member"})
    target = other_company()

    {:ok, _membership} =
      Companies.create_membership(%{
        user_id: user.id,
        company_id: target.id,
        role: "member",
        is_board_member: true
      })

    conn =
      put(conn, ~p"/api/companies/#{target.id}", %{
        "company" => %{"name" => "Board-managed target"}
      })

    assert %{"data" => %{"id" => target_id, "name" => "Board-managed target"}} =
             json_response(conn, 200)

    assert target_id == target.id
  end

  test "board authority in the current company does not govern a path-target company", %{
    conn: conn
  } do
    {conn, user, _current_company} =
      register_and_log_in_user(conn, %{role: "member", is_board_member: true})

    target = other_company()

    {:ok, _membership} =
      Companies.create_membership(%{
        user_id: user.id,
        company_id: target.id,
        role: "member",
        is_board_member: false
      })

    {:ok, target_board_user} =
      Cympho.Users.create_user(%{
        name: "Target board member",
        email: "target-board-#{System.unique_integer([:positive])}@example.com",
        password: "password1234"
      })

    {:ok, _target_board_membership} =
      Companies.create_membership(%{
        user_id: target_board_user.id,
        company_id: target.id,
        role: "member",
        is_board_member: true
      })

    conn =
      patch(conn, ~p"/api/companies/#{target.id}/governance-config", %{
        "governance_config" => %{"threshold_type" => "all"}
      })

    assert json_response(conn, 403)
    refute Companies.get_company!(target.id).governance_config["threshold_type"] == "all"
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
