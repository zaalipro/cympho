defmodule Cympho.ProjectsCompanyRequirementTest do
  use Cympho.DataCase, async: true

  alias Cympho.Projects

  test "create_project without company_id is invalid" do
    assert {:error, changeset} =
             Projects.create_project(%{"name" => "Orphan", "prefix" => "ORPH"})

    assert %{company_id: ["can't be blank"]} = errors_on(changeset)
  end

  test "create_project with company_id succeeds" do
    {:ok, company} =
      Cympho.Companies.create_company(%{
        name: "Proj Co",
        slug: "proj-co-#{System.unique_integer([:positive])}"
      })

    assert {:ok, project} =
             Projects.create_project(%{
               "name" => "Real",
               "prefix" => "REAL",
               "company_id" => company.id
             })

    assert project.company_id == company.id
  end
end
