defmodule Cympho.OnboardingTest do
  use Cympho.DataCase, async: true

  alias Cympho.Companies
  alias Cympho.Companies.Company
  alias Cympho.Goals.Goal
  alias Cympho.Issues.Issue
  alias Cympho.Onboarding
  alias Cympho.Repo
  alias Cympho.Users

  setup do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Users.create_user(%{
        email: "onboarding-draft-#{unique}@example.test",
        name: "Draft Owner",
        password: "password1234"
      })

    {:ok, company} =
      Companies.create_company(%{
        name: "Draft Company #{unique}",
        slug: "draft-company-#{unique}"
      })

    {:ok, _membership} =
      Companies.create_membership(%{
        user_id: user.id,
        company_id: company.id,
        role: "owner"
      })

    %{company: company, user: user}
  end

  test "draft persistence keeps only allowlisted non-secret fields", %{user: user} do
    assert {:ok, _user} =
             Onboarding.save_draft(user.id, %{
               "path" => "start",
               "current_step" => 99,
               "form" => %{
                 "blueprint" => "software",
                 "name" => "Restored Company",
                 "goal_title" => "Improve customer activation",
                 "project_name" => "Activation",
                 "issue_prefix" => "ACT",
                 "engineer_count" => "3",
                 "engineer_names" => ["Ada", "token=never-store-this", "Grace"],
                 "adapter" => "codex",
                 "runtime_model" => "provider-model-secret",
                 "runtime_command" => "export API_KEY=never-store-this",
                 "role_runtimes" => %{
                   "ceo" => %{"command" => "password=never-store-this"}
                 },
                 "api_key" => "never-store-this",
                 "password" => "never-store-this",
                 "provider_token" => "never-store-this"
               }
             })

    draft = Onboarding.get_draft(user.id)

    assert draft["path"] == "start"
    assert draft["current_step"] == 3
    assert draft["form"]["name"] == "Restored Company"
    assert draft["form"]["goal_title"] == "Improve customer activation"
    assert draft["form"]["engineer_names"] == ["Ada", "Grace"]
    assert draft["form"]["adapter"] == "codex"

    serialized = inspect(draft)
    assert draft["form"]["runtime_model"] == "provider-model-secret"
    refute serialized =~ "runtime_command"
    refute serialized =~ "role_runtimes"
    refute serialized =~ "api_key"
    refute serialized =~ "password"
    refute serialized =~ "provider_token"
    refute serialized =~ "never-store-this"
  end

  test "secret-like values in otherwise safe text fields are discarded", %{user: user} do
    assert {:ok, _user} =
             Onboarding.save_draft(user.id, %{
               path: "improve",
               current_step: 0,
               form: %{
                 goal_title: "Password: do-not-store",
                 improvement_details: "token=redacted-example",
                 name: "Safe company name"
               }
             })

    draft = Onboarding.get_draft(user.id)
    assert draft["form"] == %{"name" => "Safe company name"}
    refute inspect(draft) =~ "do-not-store"
    refute inspect(draft) =~ "redacted-example"
  end

  test "clearing removes the resumable draft", %{user: user} do
    assert {:ok, _user} =
             Onboarding.save_draft(user.id, %{
               "path" => "start",
               "form" => %{"name" => "Temporary Company"}
             })

    assert Onboarding.get_draft(user.id) != %{}
    assert {:ok, _user} = Onboarding.clear_draft(user.id)
    assert Onboarding.get_draft(user.id) == %{}
  end

  test "improve creates one goal and issue in the existing company without a company duplicate",
       %{
         company: company,
         user: user
       } do
    company_count = Repo.aggregate(Company, :count, :id)

    assert {:ok, %{goal: goal, issue: issue}} =
             Onboarding.create_improvement(company.id, user.id, %{
               "goal_title" => "Improve onboarding activation",
               "improvement_details" => "New owners should reach their first useful issue faster."
             })

    assert Repo.aggregate(Company, :count, :id) == company_count
    assert goal.company_id == company.id
    assert goal.title == "Improve onboarding activation"
    assert issue.company_id == company.id
    assert issue.goal_id == goal.id
    assert issue.created_by_user_id == user.id
    assert issue.origin_type == "onboarding_improvement"
    assert issue.assigned_role == "ceo"
    assert issue.description =~ "New owners should reach their first useful issue faster."
  end

  test "improve atomically clears its draft and reuses a stale replay", %{
    company: company,
    user: user
  } do
    submission_id = Ecto.UUID.generate()

    draft = %{
      "path" => "improve",
      "company_id" => company.id,
      "submission_id" => submission_id,
      "form" => %{"goal_title" => "Make owner handoffs clearer"}
    }

    assert {:ok, _user} = Onboarding.save_draft(user.id, draft)

    attrs = %{
      "submission_id" => submission_id,
      "goal_title" => "Make owner handoffs clearer",
      "improvement_details" => "Show the next decision in plain language."
    }

    assert {:ok, first} = Onboarding.create_improvement(company.id, user.id, attrs)
    assert Onboarding.get_draft(user.id) == %{}

    # Simulate a disconnected browser replaying the already-committed draft.
    assert {:ok, _user} = Onboarding.save_draft(user.id, draft)
    assert {:ok, replay} = Onboarding.create_improvement(company.id, user.id, attrs)

    assert replay.goal.id == first.goal.id
    assert replay.issue.id == first.issue.id
    assert Repo.aggregate(Goal, :count, :id) == 1
    assert Repo.aggregate(Issue, :count, :id) == 1
    assert Onboarding.get_draft(user.id) == %{}
  end

  test "an improve draft is pinned to its company", %{company: company, user: user} do
    unique = System.unique_integer([:positive])

    {:ok, other_company} =
      Companies.create_company(%{
        name: "Other draft company #{unique}",
        slug: "other-draft-company-#{unique}"
      })

    assert {:ok, _user} =
             Onboarding.save_draft(user.id, %{
               "path" => "improve",
               "company_id" => company.id,
               "submission_id" => Ecto.UUID.generate(),
               "form" => %{"goal_title" => "Improve only the intended company"}
             })

    assert Onboarding.get_draft(user.id, company.id)["form"]["goal_title"] ==
             "Improve only the intended company"

    assert Onboarding.get_draft(user.id, other_company.id) == %{}
  end

  test "improve rejects a user outside the company without partial rows", %{company: company} do
    unique = System.unique_integer([:positive])

    {:ok, outsider} =
      Users.create_user(%{
        email: "onboarding-outsider-#{unique}@example.test",
        name: "Outside User",
        password: "password1234"
      })

    assert {:error, :forbidden} =
             Onboarding.create_improvement(company.id, outsider.id, %{
               "goal_title" => "Foreign improvement"
             })

    assert Repo.aggregate(Goal, :count, :id) == 0
    assert Repo.aggregate(Issue, :count, :id) == 0
  end

  test "improve rejects a regular member without partial rows", %{
    company: company,
    user: user
  } do
    membership = Companies.get_membership(user.id, company.id)
    assert {:ok, _membership} = Companies.update_membership(membership, %{role: "member"})

    assert {:error, :forbidden} =
             Onboarding.create_improvement(company.id, user.id, %{
               "goal_title" => "Member-created improvement"
             })

    assert Repo.aggregate(Goal, :count, :id) == 0
    assert Repo.aggregate(Issue, :count, :id) == 0
  end
end
