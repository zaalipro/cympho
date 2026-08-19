defmodule CymphoWeb.DocumentControllerTest do
  use CymphoWeb.ConnCase, async: false

  alias Cympho.{Companies, Documents, Issues}
  alias Cympho.Users.User

  defp create_user do
    unique = System.unique_integer([:positive])

    %User{}
    |> User.registration_changeset(%{
      email: "doc-api-#{unique}@example.com",
      name: "Doc API Test #{unique}",
      password: "password123"
    })
    |> Cympho.Repo.insert!()
  end

  defp authed_conn(conn, user, company_id) do
    {:ok, token} = Cympho.UserAuthJWT.generate_token(user, company_id)
    Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> token)
  end

  setup %{conn: conn} do
    unique = System.unique_integer([:positive])
    user = create_user()

    {:ok, company} =
      Companies.create_company(%{
        name: "Doc API Company #{unique}",
        slug: "doc-api-company-#{unique}"
      })

    {:ok, _membership} =
      Companies.create_membership(%{
        user_id: user.id,
        company_id: company.id,
        role: "admin"
      })

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Doc API Issue",
        description: "Issue carrying a document",
        status: :backlog,
        priority: :high,
        company_id: company.id
      })

    {:ok, doc} =
      Documents.create_document(%{
        key: "plan",
        title: "Plan",
        body: "alpha\nbravo\ncharlie",
        issue_id: issue.id
      })

    {:ok, doc} = Documents.update_document(doc, %{body: "alpha\nDELTA\ncharlie"})
    {:ok, doc} = Documents.update_document(doc, %{body: "unused"})

    [newer, older] = Documents.list_revisions(doc.id)

    %{
      conn: authed_conn(conn, user, company.id),
      issue: issue,
      document: doc,
      newer: newer,
      older: older
    }
  end

  describe "GET .../revisions/:revision_id/diff" do
    test "renders a diff between two revisions", %{
      conn: conn,
      issue: issue,
      document: document,
      newer: newer,
      older: older
    } do
      conn =
        get(
          conn,
          ~p"/api/issues/#{issue.id}/documents/#{document.key}/revisions/#{newer.id}/diff",
          %{"other_revision_id" => older.id}
        )

      assert %{"data" => data} = json_response(conn, 200)
      assert data["target"]["id"] == newer.id
      assert data["base"]["id"] == older.id

      assert data["diff"] == [
               %{"type" => "same", "line" => "alpha"},
               %{"type" => "deletion", "line" => "bravo"},
               %{"type" => "addition", "line" => "DELTA"},
               %{"type" => "same", "line" => "charlie"}
             ]
    end

    test "lists revisions", %{conn: conn, issue: issue, document: document} do
      conn = get(conn, ~p"/api/issues/#{issue.id}/documents/#{document.key}/revisions")

      assert %{"data" => revisions} = json_response(conn, 200)
      assert length(revisions) == 2
      assert Enum.map(revisions, & &1["revision_number"]) == [2, 1]
    end

    test "shows a single revision", %{
      conn: conn,
      issue: issue,
      document: document,
      newer: newer
    } do
      conn =
        get(conn, ~p"/api/issues/#{issue.id}/documents/#{document.key}/revisions/#{newer.id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == newer.id
      assert data["body"] == "alpha\nDELTA\ncharlie"
    end

    test "404s for a revision belonging to another document", %{
      conn: conn,
      issue: issue,
      document: document,
      newer: newer
    } do
      {:ok, other_doc} =
        Documents.create_document(%{
          key: "other",
          title: "Other",
          body: "x",
          issue_id: issue.id
        })

      {:ok, other_doc} = Documents.update_document(other_doc, %{body: "y"})
      [foreign_revision] = Documents.list_revisions(other_doc.id)

      conn =
        get(
          conn,
          ~p"/api/issues/#{issue.id}/documents/#{document.key}/revisions/#{newer.id}/diff",
          %{"other_revision_id" => foreign_revision.id}
        )

      assert json_response(conn, 404)
    end

    test "404s when either revision ID belongs to another company", %{
      conn: conn,
      issue: issue,
      document: document,
      newer: newer,
      older: older
    } do
      unique = System.unique_integer([:positive])

      {:ok, other_company} =
        Companies.create_company(%{
          name: "Foreign Doc Company #{unique}",
          slug: "foreign-doc-company-#{unique}"
        })

      {:ok, other_issue} =
        Issues.create_issue(%{
          title: "Foreign Doc Issue",
          status: :backlog,
          company_id: other_company.id
        })

      {:ok, other_document} =
        Documents.create_document(%{
          key: "foreign-plan",
          title: "Foreign Plan",
          body: "private revision",
          issue_id: other_issue.id
        })

      {:ok, other_document} =
        Documents.update_document(other_document, %{body: "still private"})

      [foreign_revision] = Documents.list_revisions(other_document.id)

      forged_target =
        get(
          conn,
          ~p"/api/issues/#{issue.id}/documents/#{document.key}/revisions/#{foreign_revision.id}/diff",
          %{"other_revision_id" => older.id}
        )

      forged_base =
        get(
          conn,
          ~p"/api/issues/#{issue.id}/documents/#{document.key}/revisions/#{newer.id}/diff",
          %{"other_revision_id" => foreign_revision.id}
        )

      assert json_response(forged_target, 404)
      assert json_response(forged_base, 404)
    end
  end
end
