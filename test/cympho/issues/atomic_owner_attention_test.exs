defmodule Cympho.Issues.AtomicOwnerAttentionTest do
  @moduledoc """
  Atomic checkout/release/clear_checkout_lock update status via update_all and
  must notify OwnerAttention when human-action membership changes (e.g. off
  :blocked or into a terminal status).
  """
  use Cympho.DataCase, async: true

  import Ecto.Query

  alias Cympho.Agents
  alias Cympho.Companies
  alias Cympho.Issues
  alias Cympho.Issues.Issue
  alias Cympho.OwnerAttention
  alias Cympho.Repo
  alias Cympho.Users

  setup do
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{
        name: "Atomic OA Co #{unique}",
        slug: "atomic-oa-#{unique}"
      })

    {:ok, user} =
      Users.create_user(%{
        email: "atomic-oa-#{unique}@example.com",
        name: "Atomic OA Owner",
        password: "password1234"
      })

    {:ok, _membership} =
      Companies.create_membership(%{
        user_id: user.id,
        company_id: company.id,
        role: "owner"
      })

    {:ok, agent} =
      Agents.create_agent(%{
        name: "Atomic OA Agent",
        role: :engineer,
        company_id: company.id
      })

    %{company: company, user: user, agent: agent}
  end

  test "atomic checkout off :blocked notifies owner attention", %{
    company: company,
    agent: agent
  } do
    {:ok, issue} =
      Issues.create_issue(%{
        title: "Blocked for checkout",
        description: "Needs agent pickup",
        status: :blocked,
        priority: :high,
        company_id: company.id
      })

    :ok = OwnerAttention.subscribe(company.id)

    assert {:ok, checked_out} = Issues.checkout_issue(issue, agent)
    assert checked_out.status == :in_progress
    assert checked_out.assignee_id == agent.id

    assert_receive {:owner_attention_changed, company_id}
    assert company_id == company.id
  end

  test "force_release to terminal status notifies owner attention", %{
    company: company,
    user: user,
    agent: agent
  } do
    {:ok, issue} =
      Issues.create_issue(%{
        title: "Human owned work",
        description: "Force release terminal",
        status: :todo,
        priority: :medium,
        company_id: company.id,
        assignee_user_id: user.id
      })

    {:ok, checked_out} = Issues.checkout_issue(issue, agent)
    assert checked_out.status == :in_progress

    :ok = OwnerAttention.subscribe(company.id)

    assert {:ok, released} = Issues.force_release_issue(checked_out, :done)
    assert released.status == :done

    assert_receive {:owner_attention_changed, company_id}
    assert company_id == company.id
  end

  test "release_issue off :blocked notifies owner attention", %{
    company: company,
    agent: agent
  } do
    {:ok, issue} =
      Issues.create_issue(%{
        title: "Blocked release",
        description: "Release after stall",
        status: :todo,
        priority: :medium,
        company_id: company.id
      })

    {:ok, checked_out} = Issues.checkout_issue(issue, agent)

    # Simulate stranded blocked ownership without going through update_issue notify.
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {1, _} =
      from(i in Issue, where: i.id == ^checked_out.id)
      |> Repo.update_all(set: [status: :blocked, updated_at: now], inc: [lock_version: 1])

    blocked = Issues.get_issue!(checked_out.id)
    assert blocked.status == :blocked

    :ok = OwnerAttention.subscribe(company.id)

    assert {:ok, released} = Issues.release_issue(blocked, :todo)
    assert released.status == :todo
    assert is_nil(released.assignee_id)

    assert_receive {:owner_attention_changed, company_id}
    assert company_id == company.id
  end

  test "clear_checkout_lock to terminal status notifies owner attention", %{
    company: company,
    user: user,
    agent: agent
  } do
    {:ok, issue} =
      Issues.create_issue(%{
        title: "Clear lock terminal",
        description: "Recover and close",
        status: :todo,
        priority: :medium,
        company_id: company.id,
        assignee_user_id: user.id
      })

    {:ok, checked_out} = Issues.checkout_issue(issue, agent)
    assert checked_out.checked_out_at

    :ok = OwnerAttention.subscribe(company.id)

    assert {:ok, recovered} = Issues.clear_checkout_lock(checked_out, :cancelled)
    assert recovered.status == :cancelled
    assert recovered.assignee_id == agent.id
    assert is_nil(recovered.checked_out_at)

    assert_receive {:owner_attention_changed, company_id}
    assert company_id == company.id
  end

  test "clear_checkout_lock_for_run status change notifies owner attention", %{
    company: company,
    user: user,
    agent: agent
  } do
    {:ok, issue} =
      Issues.create_issue(%{
        title: "Run clear terminal",
        description: "Terminalize via run clear",
        status: :todo,
        priority: :medium,
        company_id: company.id,
        assignee_user_id: user.id,
        assignee_id: agent.id
      })

    assert {:ok, run} =
             Cympho.HeartbeatEngine.create_run(%{
               company_id: company.id,
               agent_id: agent.id,
               issue_id: issue.id,
               adapter: "claude_code"
             })

    assert {:ok, bound} = Issues.bind_checkout_run(issue.id, agent.id, run.id)
    assert bound.checkout_run_id == run.id
    assert bound.status == :in_progress

    :ok = OwnerAttention.subscribe(company.id)

    assert {:ok, cleared} =
             Issues.clear_checkout_lock_for_run(issue.id, agent.id, run.id, :done)

    assert cleared.status == :done
    assert is_nil(cleared.checkout_run_id)

    assert_receive {:owner_attention_changed, company_id}
    assert company_id == company.id
  end

  test "same-audience atomic checkout does not notify", %{company: company, agent: agent} do
    {:ok, issue} =
      Issues.create_issue(%{
        title: "Todo checkout quiet",
        description: "No membership change",
        status: :todo,
        priority: :low,
        company_id: company.id
      })

    :ok = OwnerAttention.subscribe(company.id)

    assert {:ok, _checked_out} = Issues.checkout_issue(issue, agent)
    refute_receive {:owner_attention_changed, _}, 50
  end
end
