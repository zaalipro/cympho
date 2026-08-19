defmodule CymphoWeb.WorkProductControllerTest do
  use CymphoWeb.ConnCase, async: true

  alias Cympho.{Attachments, Companies, Issues, WorkProducts}

  defp create_attachment(issue, filename) do
    Attachments.create_attachment(%{
      filename: filename,
      content_type: "text/plain",
      file_size: 42,
      path: "#{issue.id}/#{filename}",
      issue_id: issue.id
    })
  end

  setup %{conn: conn} do
    {conn, _user, company} = register_and_log_in_user(conn, %{role: "admin"})

    {:ok, issue} =
      Issues.create_issue(%{
        title: "Test Issue",
        description: "Test description",
        status: :backlog,
        priority: :medium,
        company_id: company.id
      })

    %{conn: conn, issue: issue, company: company}
  end

  describe "POST /api/issues/:issue_id/work-products" do
    test "creates a work product with valid data", %{conn: conn, issue: issue} do
      params = %{
        "kind" => "code_change",
        "title" => "Implementation PR",
        "description" => "PR for the feature"
      }

      conn = post(conn, "/api/issues/#{issue.id}/work-products", params)
      assert %{"data" => data} = json_response(conn, 201)
      assert data["kind"] == "code_change"
      assert data["title"] == "Implementation PR"
      assert data["description"] == "PR for the feature"
      assert data["issue_id"] == issue.id
    end

    test "returns 422 when kind is missing", %{conn: conn, issue: issue} do
      params = %{
        "title" => "Missing kind"
      }

      conn = post(conn, "/api/issues/#{issue.id}/work-products", params)
      assert %{"errors" => _} = json_response(conn, 422)
    end

    test "returns 422 when title is missing", %{conn: conn, issue: issue} do
      params = %{
        "kind" => "document"
      }

      conn = post(conn, "/api/issues/#{issue.id}/work-products", params)
      assert %{"errors" => _} = json_response(conn, 422)
    end

    test "returns 422 when kind is invalid", %{conn: conn, issue: issue} do
      params = %{
        "kind" => "invalid_kind",
        "title" => "Test"
      }

      conn = post(conn, "/api/issues/#{issue.id}/work-products", params)
      assert %{"errors" => _} = json_response(conn, 422)
    end

    test "returns 404 for non-existent issue_id", %{conn: conn} do
      fake_issue_id = Ecto.UUID.generate()

      params = %{
        "kind" => "document",
        "title" => "Test"
      }

      conn = post(conn, "/api/issues/#{fake_issue_id}/work-products", params)
      assert json_response(conn, 404)
    end

    test "accepts an attachment belonging to the same issue", %{conn: conn, issue: issue} do
      {:ok, attachment} = create_attachment(issue, "same-issue.txt")

      conn =
        post(conn, "/api/issues/#{issue.id}/work-products", %{
          "kind" => "artifact",
          "title" => "Attached evidence",
          "attachment_id" => attachment.id
        })

      assert %{"data" => %{"attachment_id" => attachment_id}} = json_response(conn, 201)
      assert attachment_id == attachment.id
    end

    test "rejects a forged attachment_id from another issue", %{
      conn: conn,
      issue: issue,
      company: company
    } do
      {:ok, other_issue} =
        Issues.create_issue(%{
          title: "Other attachment issue",
          status: :todo,
          company_id: company.id
        })

      {:ok, attachment} = create_attachment(other_issue, "other-issue.txt")

      conn =
        post(conn, "/api/issues/#{issue.id}/work-products", %{
          "kind" => "artifact",
          "title" => "Forged evidence",
          "attachment_id" => attachment.id
        })

      assert %{"errors" => %{"attachment_id" => ["must belong to the same issue"]}} =
               json_response(conn, 422)
    end

    test "rejects a forged attachment_id from another company", %{conn: conn, issue: issue} do
      unique = System.unique_integer([:positive])

      {:ok, other_company} =
        Companies.create_company(%{
          name: "Foreign Work Product #{unique}",
          slug: "foreign-work-product-#{unique}"
        })

      {:ok, other_issue} =
        Issues.create_issue(%{
          title: "Foreign attachment issue",
          status: :todo,
          company_id: other_company.id
        })

      {:ok, attachment} = create_attachment(other_issue, "foreign-issue.txt")

      conn =
        post(conn, "/api/issues/#{issue.id}/work-products", %{
          "kind" => "artifact",
          "title" => "Cross-tenant evidence",
          "attachment_id" => attachment.id
        })

      assert %{"errors" => %{"attachment_id" => ["must belong to the same issue"]}} =
               json_response(conn, 422)
    end
  end

  describe "GET /api/issues/:issue_id/work-products" do
    test "returns empty list when no work products exist", %{conn: conn, issue: issue} do
      conn = get(conn, "/api/issues/#{issue.id}/work-products")
      assert %{"data" => []} = json_response(conn, 200)
    end

    test "returns work products newest first", %{conn: conn, issue: issue} do
      {:ok, wp1} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          kind: "document",
          title: "First document"
        })

      # Backdate wp1 so second-precision inserted_at ordering is deterministic
      # without sleeping across a second boundary.
      earlier = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-60)
      {:ok, wp1} = Cympho.Repo.update(Ecto.Changeset.change(wp1, inserted_at: earlier))

      {:ok, wp2} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          kind: "code_change",
          title: "Second document"
        })

      conn = get(conn, "/api/issues/#{issue.id}/work-products")
      assert %{"data" => [first, second]} = json_response(conn, 200)
      assert first["id"] == wp2.id
      assert second["id"] == wp1.id
      assert first["title"] == "Second document"
      assert second["title"] == "First document"
    end
  end

  describe "GET /api/issues/:issue_id/work-products/:id" do
    test "returns a work product", %{conn: conn, issue: issue} do
      {:ok, wp} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          kind: "url",
          title: "Link to PR",
          url: "https://github.com/example/pr/1"
        })

      conn = get(conn, "/api/issues/#{issue.id}/work-products/#{wp.id}")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == wp.id
      assert data["title"] == "Link to PR"
      assert data["url"] == "https://github.com/example/pr/1"
    end

    test "returns 404 for non-existent work product", %{conn: conn, issue: issue} do
      fake_id = Ecto.UUID.generate()
      conn = get(conn, "/api/issues/#{issue.id}/work-products/#{fake_id}")
      assert %{"errors" => _} = json_response(conn, 404)
    end

    test "returns 404 when a work-product ID is forged under another issue", %{
      conn: conn,
      issue: issue,
      company: company
    } do
      {:ok, other_issue} =
        Issues.create_issue(%{title: "Other work product issue", company_id: company.id})

      {:ok, work_product} =
        WorkProducts.create_work_product(%{
          issue_id: other_issue.id,
          kind: "document",
          title: "Other issue private evidence"
        })

      conn = get(conn, "/api/issues/#{issue.id}/work-products/#{work_product.id}")
      assert json_response(conn, 404)
    end
  end

  describe "PATCH /api/issues/:issue_id/work-products/:id" do
    test "updates a work product", %{conn: conn, issue: issue} do
      {:ok, wp} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          kind: "document",
          title: "Original title"
        })

      params = %{"title" => "Updated title", "description" => "New description"}

      conn = patch(conn, "/api/issues/#{issue.id}/work-products/#{wp.id}", params)
      assert %{"data" => data} = json_response(conn, 200)
      assert data["title"] == "Updated title"
      assert data["description"] == "New description"
      assert data["kind"] == "document"
    end

    test "returns 422 when updating with invalid kind", %{conn: conn, issue: issue} do
      {:ok, wp} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          kind: "document",
          title: "Test"
        })

      params = %{"kind" => "invalid_kind"}

      conn = patch(conn, "/api/issues/#{issue.id}/work-products/#{wp.id}", params)
      assert %{"errors" => _} = json_response(conn, 422)
    end

    test "rejects a forged attachment_id when updating", %{
      conn: conn,
      issue: issue,
      company: company
    } do
      {:ok, work_product} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          kind: "document",
          title: "Original evidence"
        })

      {:ok, other_issue} =
        Issues.create_issue(%{title: "Other update issue", company_id: company.id})

      {:ok, attachment} = create_attachment(other_issue, "forged-update.txt")

      conn =
        patch(conn, "/api/issues/#{issue.id}/work-products/#{work_product.id}", %{
          "attachment_id" => attachment.id
        })

      assert %{"errors" => %{"attachment_id" => ["must belong to the same issue"]}} =
               json_response(conn, 422)

      assert {:ok, unchanged} = WorkProducts.get_work_product(work_product.id)
      assert unchanged.attachment_id == nil
    end

    test "returns 404 for non-existent work product", %{conn: conn, issue: issue} do
      fake_id = Ecto.UUID.generate()
      params = %{"title" => "New title"}

      conn = patch(conn, "/api/issues/#{issue.id}/work-products/#{fake_id}", params)
      assert %{"errors" => _} = json_response(conn, 404)
    end
  end

  describe "DELETE /api/issues/:issue_id/work-products/:id" do
    test "deletes a work product", %{conn: conn, issue: issue} do
      {:ok, wp} =
        WorkProducts.create_work_product(%{
          issue_id: issue.id,
          kind: "artifact",
          title: "To be deleted"
        })

      conn = delete(conn, "/api/issues/#{issue.id}/work-products/#{wp.id}")
      assert response(conn, 204)

      assert {:error, :not_found} = WorkProducts.get_work_product(wp.id)
    end

    test "returns 404 for non-existent work product", %{conn: conn, issue: issue} do
      fake_id = Ecto.UUID.generate()
      conn = delete(conn, "/api/issues/#{issue.id}/work-products/#{fake_id}")
      assert %{"errors" => _} = json_response(conn, 404)
    end
  end
end
