defmodule Cympho.ApprovalsTest do
  use Cympho.DataCase, async: false

  alias Cympho.Approvals
  alias Cympho.Approvals.Approval
  alias Cympho.Decisions.Decision

  describe "create_approval/1" do
    test "creates an approval with valid attrs" do
      agent = insert_agent()
      attrs = %{type: "request_board_approval", requested_by_agent_id: agent.id}

      assert {:ok, %Approval{} = approval} = Approvals.create_approval(attrs)
      assert approval.type == "request_board_approval"
      assert approval.status == :pending
      assert approval.requested_by_agent_id == agent.id
    end

    test "creates an approval with linked issues" do
      agent = insert_agent()
      issue = insert_issue()

      attrs = %{
        type: "request_board_approval",
        requested_by_agent_id: agent.id,
        issue_ids: [issue.id]
      }

      assert {:ok, %Approval{} = approval} = Approvals.create_approval(attrs)
      assert length(approval.issues) == 1
      assert hd(approval.issues).id == issue.id
    end

    test "returns error with missing type" do
      agent = insert_agent()
      attrs = %{requested_by_agent_id: agent.id}

      assert {:error, changeset} = Approvals.create_approval(attrs)
      assert %{type: ["can't be blank"]} = errors_on(changeset)
    end

    test "returns error with missing requested_by_agent_id" do
      attrs = %{type: "request_board_approval"}

      assert {:error, changeset} = Approvals.create_approval(attrs)
      assert %{requested_by_agent_id: ["can't be blank"]} = errors_on(changeset)
    end

    test "creates with payload" do
      agent = insert_agent()

      attrs = %{
        type: "request_board_approval",
        requested_by_agent_id: agent.id,
        payload: %{"summary" => "Test summary", "amount" => 100}
      }

      assert {:ok, %Approval{} = approval} = Approvals.create_approval(attrs)
      assert approval.payload["summary"] == "Test summary"
    end

    test "broadcasts to company-scoped topic when creating approval without issues" do
      company = insert_company()
      agent = insert_agent(company_id: company.id)

      attrs = %{
        type: "request_board_approval",
        requested_by_agent_id: agent.id
      }

      Approvals.subscribe(company.id)
      {:ok, _approval} = Approvals.create_approval(attrs)

      assert_received {:approval_created, _}
    end
  end

  describe "resolve_approval/3" do
    test "approves a pending approval" do
      agent = insert_agent()
      {:ok, approval} = create_test_approval(agent)

      assert {:ok, updated} =
               Approvals.resolve_approval(approval.id, :approved, %{
                 resolution_reason: "Looks good"
               })

      assert updated.status == :approved
      assert updated.resolution_reason == "Looks good"
    end

    test "denies a pending approval" do
      agent = insert_agent()
      {:ok, approval} = create_test_approval(agent)

      assert {:ok, updated} =
               Approvals.resolve_approval(approval.id, :denied, %{
                 resolution_reason: "Too expensive"
               })

      assert updated.status == :denied
    end

    test "returns error when resolving non-pending approval" do
      agent = insert_agent()
      {:ok, approval} = create_test_approval(agent)

      {:ok, approved} = Approvals.resolve_approval(approval.id, :approved, %{})

      assert {:error, :not_pending} = Approvals.resolve_approval(approved.id, :denied, %{})
    end

    test "broadcasts approval_resolved event" do
      company = insert_company()
      agent = insert_agent(company_id: company.id)
      issue = insert_issue(company_id: company.id)
      {:ok, approval} = create_test_approval(agent, issue)

      Approvals.subscribe(company.id)
      {:ok, _} = Approvals.resolve_approval(approval.id, :approved, %{})

      assert_received {:approval_resolved, _}
    end

    test "broadcasts to company-scoped topic when approval has no issues" do
      company = insert_company()
      agent = insert_agent(company_id: company.id)
      {:ok, approval} = create_test_approval(agent)

      Approvals.subscribe(company.id)
      {:ok, _} = Approvals.resolve_approval(approval.id, :approved, %{})

      assert_received {:approval_resolved, _}
    end

    test "commits the approval and its company-scoped Decision together" do
      company = insert_company()
      agent = insert_agent(company_id: company.id)
      {:ok, approval} = create_test_approval(agent)

      assert {:ok, updated} =
               Approvals.resolve_approval(approval.id, :approved, %{
                 resolution_reason: "Approved with an audit decision"
               })

      decision =
        Repo.one!(
          from(d in Decision,
            where: d.resource_type == "approval" and d.resource_id == ^approval.id
          )
        )

      assert updated.status == :approved
      assert decision.company_id == company.id
      assert decision.outcome == "approved"
      assert decision.reasoning == "Approved with an audit decision"
    end

    test "rolls back the status when the required Decision cannot be recorded" do
      agent = insert_agent(without_company: true)
      {:ok, approval} = create_test_approval(agent)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Approvals.resolve_approval(approval.id, :approved, %{})

      assert %{company_id: ["can't be blank"]} = errors_on(changeset)
      assert Approvals.get_approval!(approval.id).status == :pending

      refute Repo.exists?(
               from(d in Decision,
                 where: d.resource_type == "approval" and d.resource_id == ^approval.id
               )
             )
    end

    test "only one concurrent contradictory resolution wins" do
      company = insert_company()
      agent = insert_agent(company_id: company.id)
      {:ok, approval} = create_test_approval(agent)

      results =
        run_concurrently([
          fn -> Approvals.resolve_approval(approval.id, :approved, %{}) end,
          fn -> Approvals.resolve_approval(approval.id, :denied, %{}) end
        ])

      assert 1 == Enum.count(results, &match?({:ok, %Approval{}}, &1))
      assert 1 == Enum.count(results, &match?({:error, :not_pending}, &1))

      resolved = Approvals.get_approval!(approval.id)

      [decision] =
        Repo.all(
          from(d in Decision,
            where: d.resource_type == "approval" and d.resource_id == ^approval.id
          )
        )

      assert resolved.status in [:approved, :denied]
      assert decision.outcome == to_string(resolved.status)
    end

    test "cancellation and resolution use the same pending-state compare-and-set" do
      company = insert_company()
      agent = insert_agent(company_id: company.id)
      {:ok, approval} = create_test_approval(agent)

      results =
        run_concurrently([
          fn -> Approvals.resolve_approval(approval.id, :approved, %{}) end,
          fn -> Approvals.cancel_approval(approval.id) end
        ])

      assert 1 == Enum.count(results, &match?({:ok, %Approval{}}, &1))
      assert 1 == Enum.count(results, &match?({:error, :not_pending}, &1))
      assert Approvals.get_approval!(approval.id).status in [:approved, :cancelled]
    end
  end

  describe "resolver authorization" do
    test "permits owners, admins, and board members but not ordinary members" do
      company = insert_company()
      owner = insert_member(company, "owner")
      admin = insert_member(company, "admin")
      board_member = insert_member(company, "member", true)
      member = insert_member(company, "member")
      viewer = insert_member(company, "viewer")
      viewer_board_member = insert_member(company, "viewer", true)

      assert Approvals.resolver_authorized?(owner.id, company.id)
      assert Approvals.resolver_authorized?(admin.id, company.id)
      assert Approvals.resolver_authorized?(board_member.id, company.id)
      refute Approvals.resolver_authorized?(member.id, company.id)
      refute Approvals.resolver_authorized?(viewer.id, company.id)
      refute Approvals.resolver_authorized?(viewer_board_member.id, company.id)
    end

    test "company-scoped resolution rejects an unauthorized member without mutation" do
      company = insert_company()
      member = insert_member(company, "member")
      agent = insert_agent(company_id: company.id)
      {:ok, approval} = create_test_approval(agent)

      assert {:error, :forbidden} =
               Approvals.resolve_company_approval(company.id, approval.id, :approved, %{
                 resolved_by_user_id: member.id
               })

      assert Approvals.get_approval!(approval.id).status == :pending
      refute Repo.exists?(from d in Decision, where: d.resource_id == ^approval.id)
    end
  end

  describe "cancel_approval/1" do
    test "cancels a pending approval" do
      agent = insert_agent(without_company: true)
      {:ok, approval} = create_test_approval(agent)

      assert {:ok, updated} = Approvals.cancel_approval(approval.id)
      assert updated.status == :cancelled
    end

    test "returns error when cancelling non-pending approval" do
      agent = insert_agent()
      {:ok, approval} = create_test_approval(agent)
      {:ok, approved} = Approvals.resolve_approval(approval.id, :approved, %{})

      assert {:error, :not_pending} = Approvals.cancel_approval(approved.id)
    end
  end

  describe "cancel_pending_for_issue/1" do
    test "cancels all pending approvals linked to an issue" do
      agent = insert_agent()
      issue = insert_issue()

      {:ok, _approval} =
        Approvals.create_approval(%{
          type: "request_board_approval",
          requested_by_agent_id: agent.id,
          issue_ids: [issue.id]
        })

      assert {:ok, 1} = Approvals.cancel_pending_for_issue(issue.id)
    end

    test "does not cancel already-resolved approvals" do
      agent = insert_agent()
      issue = insert_issue()

      {:ok, approval} =
        Approvals.create_approval(%{
          type: "request_board_approval",
          requested_by_agent_id: agent.id,
          issue_ids: [issue.id]
        })

      {:ok, _} = Approvals.resolve_approval(approval.id, :approved, %{})
      assert {:ok, 0} = Approvals.cancel_pending_for_issue(issue.id)
    end
  end

  describe "list_approvals/1" do
    test "returns all approvals ordered by newest first" do
      agent = insert_agent()
      {:ok, _a1} = create_test_approval(agent)
      {:ok, _a2} = create_test_approval(agent)

      approvals = Approvals.list_approvals()
      assert length(approvals) >= 2
    end

    test "filters by status" do
      agent = insert_agent()
      {:ok, a1} = create_test_approval(agent)
      {:ok, _} = Approvals.resolve_approval(a1.id, :approved, %{})
      {:ok, _a2} = create_test_approval(agent)

      pending = Approvals.list_approvals(%{status: :pending})
      assert Enum.all?(pending, &(&1.status == :pending))
    end
  end

  describe "count_pending_for_company/1" do
    test "counts only pending approvals requested inside the company" do
      company = insert_company()
      other_company = insert_company()
      agent = insert_agent(company_id: company.id)
      other_agent = insert_agent(company_id: other_company.id)

      {:ok, pending} = create_test_approval(agent)
      {:ok, resolved} = create_test_approval(agent)
      {:ok, _other} = create_test_approval(other_agent)
      {:ok, _} = Approvals.resolve_approval(resolved.id, :approved, %{})

      assert Approvals.count_pending_for_company(company.id) == 1
      assert Approvals.count_pending_for_company(other_company.id) == 1

      {:ok, _} = Approvals.resolve_approval(pending.id, :denied, %{})
      assert Approvals.count_pending_for_company(company.id) == 0
    end
  end

  describe "get_approval/1" do
    test "returns the approval with preloads" do
      agent = insert_agent()
      {:ok, approval} = create_test_approval(agent)

      assert {:ok, found} = Approvals.get_approval(approval.id)
      assert found.id == approval.id
      assert found.requested_by.id == agent.id
    end

    test "returns error for missing id" do
      assert {:error, :not_found} = Approvals.get_approval(Ecto.UUID.generate())
    end
  end

  describe "fail-closed pubsub (lb-pubsub-fail-closed)" do
    test "does not publish unscoped approvals or company:: when company cannot be resolved" do
      # Agent with no company_id and no linked issues → no tenant topic.
      agent = insert_agent(without_company: true)
      assert is_nil(agent.company_id)

      Phoenix.PubSub.subscribe(Cympho.PubSub, "approvals")
      Phoenix.PubSub.subscribe(Cympho.PubSub, "company::approvals")

      assert {:ok, _approval} =
               Approvals.create_approval(%{
                 type: "request_board_approval",
                 requested_by_agent_id: agent.id
               })

      refute_receive {:approval_created, _}, 50
    end

    test "cancel_pending_for_issue publishes company-scoped only" do
      company = insert_company()
      agent = insert_agent(company_id: company.id)
      issue = insert_issue(company_id: company.id)

      {:ok, _} =
        Approvals.create_approval(%{
          type: "request_board_approval",
          requested_by_agent_id: agent.id,
          issue_ids: [issue.id]
        })

      Approvals.subscribe(company.id)
      Phoenix.PubSub.subscribe(Cympho.PubSub, "approvals")
      Phoenix.PubSub.subscribe(Cympho.PubSub, "company::approvals")

      assert {:ok, 1} = Approvals.cancel_pending_for_issue(issue.id)
      assert_receive {:approvals_cancelled_for_issue, issue_id}
      assert issue_id == issue.id
      refute_receive {:approvals_cancelled_for_issue, _}, 20
    end

    test "subscribe with nil company_id is a no-op" do
      assert :ok = Approvals.subscribe(nil)
    end
  end

  describe "Approval changeset validations" do
    test "create_changeset validates status is valid" do
      changeset =
        Approval.create_changeset(%Approval{}, %{
          type: "test",
          requested_by_agent_id: Ecto.UUID.generate(),
          status: :invalid_status
        })

      assert %{status: _} = errors_on(changeset)
    end

    test "resolve_changeset prevents non-pending transitions" do
      approval = %Approval{status: :approved}

      changeset =
        Approval.resolve_changeset(approval, %{
          status: :denied,
          resolved_by_user_id: Ecto.UUID.generate()
        })

      assert %{status: _} = errors_on(changeset)
    end
  end

  defp insert_company do
    Cympho.Repo.insert!(%Cympho.Companies.Company{
      name: "Test Company #{System.unique_integer()}",
      slug: "test-company-#{System.unique_integer()}"
    })
  end

  defp insert_agent(opts \\ []) do
    agent = %Cympho.Agents.Agent{
      name: "Test Agent #{System.unique_integer()}",
      role: :engineer,
      status: :idle
    }

    company_id =
      cond do
        opts[:without_company] -> nil
        opts[:company_id] -> opts[:company_id]
        true -> insert_company().id
      end

    agent = %{agent | company_id: company_id}

    %{id: id} = Cympho.Repo.insert!(agent)
    Cympho.Repo.get!(Cympho.Agents.Agent, id)
  end

  defp insert_issue(opts \\ []) do
    project = %Cympho.Projects.Project{
      name: "Test Project #{System.unique_integer()}",
      prefix: "TST"
    }

    project =
      if opts[:company_id] do
        %{project | company_id: opts[:company_id]}
      else
        {:ok, company} =
          Cympho.Companies.create_company(%{
            name: "Approvals Co",
            slug: "approvals-co-#{System.unique_integer([:positive])}"
          })

        %{project | company_id: company.id}
      end

    project = Cympho.Repo.insert!(project)

    issue_attrs = %{
      title: "Test Issue",
      description: "Test description",
      project_id: project.id
    }

    issue_attrs =
      if opts[:company_id] do
        Map.put(issue_attrs, :company_id, opts[:company_id])
      else
        issue_attrs
      end

    {:ok, issue} = Cympho.Issues.create_issue(issue_attrs)
    issue
  end

  defp create_test_approval(agent, issue \\ nil) do
    attrs = %{
      type: "request_board_approval",
      requested_by_agent_id: agent.id
    }

    attrs =
      if issue do
        Map.put(attrs, :issue_ids, [issue.id])
      else
        attrs
      end

    Approvals.create_approval(attrs)
  end

  defp insert_member(company, role, board_member \\ false) do
    unique = System.unique_integer([:positive])

    {:ok, user} =
      Cympho.Users.create_user(%{
        email: "approval-resolver-#{unique}@example.com",
        name: "Approval Resolver #{unique}",
        password: "password1234"
      })

    {:ok, _membership} =
      Cympho.Companies.create_membership(%{
        user_id: user.id,
        company_id: company.id,
        role: role,
        is_board_member: board_member
      })

    user
  end

  defp run_concurrently(funs) do
    parent = self()

    tasks =
      Enum.map(funs, fn fun ->
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :go -> fun.()
          end
        end)
      end)

    task_pids = Enum.map(tasks, & &1.pid)
    Enum.each(task_pids, fn pid -> assert_receive {:ready, ^pid} end)
    Enum.each(task_pids, &send(&1, :go))
    Task.await_many(tasks, 5_000)
  end
end
