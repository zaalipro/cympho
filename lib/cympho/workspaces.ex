defmodule Cympho.Workspaces do
  @moduledoc """
  The Workspaces context manages project workspaces, execution workspaces,
  runtime services, operations, and environment leases.
  """
  import Ecto.Query, warn: false
  alias Cympho.Repo

  alias Cympho.Workspaces.ProjectWorkspace
  alias Cympho.Workspaces.ExecutionWorkspace
  alias Cympho.Workspaces.RuntimeService
  alias Cympho.Workspaces.WorkspaceOperation
  alias Cympho.Workspaces.EnvironmentLease
  alias Cympho.Workspaces.Environment
  alias Cympho.Workspaces.EnvironmentProbe
  alias Cympho.Workspaces.ExecutionWorkspacePolicy

  # --- Project Workspaces ---

  def list_project_workspaces(project_id) do
    from(pw in ProjectWorkspace, where: pw.project_id == ^project_id)
    |> Repo.all()
  end

  def list_project_workspaces_for_company(company_id) do
    from(pw in ProjectWorkspace, where: pw.company_id == ^company_id)
    |> Repo.all()
  end

  def get_project_workspace!(id), do: Repo.get!(ProjectWorkspace, id)

  def get_project_workspace(id) do
    case Repo.get(ProjectWorkspace, id) do
      nil -> {:error, :not_found}
      pw -> {:ok, pw}
    end
  end

  def create_project_workspace(attrs \\ %{}) do
    %ProjectWorkspace{}
    |> ProjectWorkspace.changeset(attrs)
    |> Repo.insert()
  end

  def update_project_workspace(%ProjectWorkspace{} = pw, attrs) do
    pw
    |> ProjectWorkspace.changeset(attrs)
    |> Repo.update()
  end

  # --- Execution Workspaces ---

  def list_execution_workspaces(project_workspace_id, opts \\ []) do
    query =
      from(ew in ExecutionWorkspace,
        where: ew.project_workspace_id == ^project_workspace_id
      )

    query = maybe_filter_by_status(query, Keyword.get(opts, :status))
    Repo.all(query)
  end

  defp maybe_filter_by_status(query, nil), do: query
  defp maybe_filter_by_status(query, status), do: where(query, status: ^status)

  def get_execution_workspace!(id), do: Repo.get!(ExecutionWorkspace, id)

  def get_execution_workspace(id) do
    case Repo.get(ExecutionWorkspace, id) do
      nil -> {:error, :not_found}
      ew -> {:ok, ew}
    end
  end

  def get_execution_workspace_for_issue(issue_id) do
    case Repo.get_by(ExecutionWorkspace, source_issue_id: issue_id) do
      nil -> {:error, :not_found}
      ew -> {:ok, ew}
    end
  end

  def create_execution_workspace(attrs \\ %{}) do
    %ExecutionWorkspace{}
    |> ExecutionWorkspace.changeset(attrs)
    |> Repo.insert()
  end

  def update_execution_workspace(%ExecutionWorkspace{} = ew, attrs) do
    ew
    |> ExecutionWorkspace.changeset(attrs)
    |> Repo.update()
  end

  def destroy_execution_workspace(%ExecutionWorkspace{} = ew) do
    update_execution_workspace(ew, %{status: "closed", closed_at: DateTime.utc_now()})
  end

  # --- Worktree Helpers ---

  def detect_default_branch(project_workspace_id) do
    case get_project_workspace(project_workspace_id) do
      {:ok, pw} ->
        default_ref = pw.default_ref || pw.repo_ref || "main"
        {:ok, %{default_branch: default_ref, project_workspace: pw}}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  def update_worktree_config(project_workspace_id, config) do
    case get_project_workspace(project_workspace_id) do
      {:ok, pw} ->
        metadata = Map.merge(pw.metadata || %{}, %{"worktree_config" => config})
        update_project_workspace(pw, %{metadata: metadata})

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  # --- Seed & Secrets ---

  def seed_worktree(%ExecutionWorkspace{} = ew, seed_config) do
    metadata = Map.merge(ew.metadata || %{}, %{"seed_config" => seed_config})
    update_execution_workspace(ew, %{metadata: metadata})
  end

  def inject_secrets(%ExecutionWorkspace{} = ew, secret_mappings) do
    metadata = Map.merge(ew.metadata || %{}, %{"secret_mappings" => secret_mappings})
    update_execution_workspace(ew, %{metadata: metadata})
  end

  # --- Runtime Services ---

  def list_runtime_services(execution_workspace_id) do
    from(rs in RuntimeService,
      where: rs.execution_workspace_id == ^execution_workspace_id
    )
    |> Repo.all()
  end

  def get_runtime_service!(id), do: Repo.get!(RuntimeService, id)

  def get_runtime_service(id) do
    case Repo.get(RuntimeService, id) do
      nil -> {:error, :not_found}
      service -> {:ok, service}
    end
  end

  def create_runtime_service(attrs \\ %{}) do
    %RuntimeService{}
    |> RuntimeService.changeset(attrs)
    |> Repo.insert()
  end

  def start_service(%RuntimeService{} = svc) do
    svc
    |> RuntimeService.changeset(%{
      status: "running",
      started_at: DateTime.utc_now(),
      stopped_at: nil
    })
    |> Repo.update()
  end

  def stop_service(%RuntimeService{} = svc) do
    svc
    |> RuntimeService.changeset(%{status: "stopped", stopped_at: DateTime.utc_now()})
    |> Repo.update()
  end

  def restart_service(%RuntimeService{} = svc) do
    svc
    |> RuntimeService.changeset(%{
      status: "running",
      started_at: DateTime.utc_now(),
      stopped_at: nil
    })
    |> Repo.update()
  end

  @doc """
  Update runtime service with discovered port information.
  """
  def update_service_port(%RuntimeService{} = svc, port, attrs \\ %{}) do
    svc
    |> RuntimeService.changeset(Map.merge(attrs, %{port: port, status: "running"}))
    |> Repo.update()
  end

  @doc """
  Set the preview URL for a runtime service.
  """
  def set_service_url(%RuntimeService{} = svc, url) do
    svc
    |> RuntimeService.changeset(%{url: url})
    |> Repo.update()
  end

  @doc """
  Auto-discover ports and infer likely dev server from project files.
  """
  def discover_service_ports(cwd) when is_binary(cwd) do
    alias Cympho.Workspaces.PreviewUrl
    PreviewUrl.infer_ports_from_project(cwd)
  end

  # --- Operations ---

  def list_operations(execution_workspace_id, opts \\ []) do
    limit = Keyword.get(opts, :limit, 50)

    from(op in WorkspaceOperation,
      where: op.execution_workspace_id == ^execution_workspace_id,
      order_by: [desc: op.inserted_at],
      limit: ^limit
    )
    |> Repo.all()
  end

  # --- Leases ---

  def create_lease(attrs \\ %{}) do
    %EnvironmentLease{}
    |> EnvironmentLease.changeset(attrs)
    |> Repo.insert()
  end

  def revoke_lease(%EnvironmentLease{} = lease) do
    lease
    |> EnvironmentLease.revoke_changeset()
    |> Repo.update()
  end

  def expire_stale_leases do
    now = DateTime.utc_now()

    from(el in EnvironmentLease,
      where: el.status == "active" and el.expires_at < ^now
    )
    |> Repo.update_all(set: [status: "expired", updated_at: now])
  end

  def cleanup_expired_workspaces do
    now = DateTime.utc_now()

    from(ew in ExecutionWorkspace,
      where: ew.status == "closed" and ew.cleanup_eligible_at < ^now
    )
    |> Repo.update_all(set: [status: "cleaned_up", updated_at: now])
  end

  # --- Environments ---

  def list_environments(project_id) do
    from(e in Environment, where: e.project_id == ^project_id)
    |> Repo.all()
  end

  def get_environment!(id), do: Repo.get!(Environment, id)

  def get_environment(id) do
    case Repo.get(Environment, id) do
      nil -> {:error, :not_found}
      env -> {:ok, env}
    end
  end

  def create_environment(attrs \\ %{}) do
    %Environment{}
    |> Environment.changeset(attrs)
    |> Repo.insert()
  end

  # --- Environment Probes ---

  def list_probes(environment_id) do
    from(p in EnvironmentProbe, where: p.environment_id == ^environment_id)
    |> Repo.all()
  end

  def list_probes_for_workspace(execution_workspace_id) do
    from(p in EnvironmentProbe, where: p.execution_workspace_id == ^execution_workspace_id)
    |> Repo.all()
  end

  def create_probe(attrs \\ %{}) do
    %EnvironmentProbe{}
    |> EnvironmentProbe.changeset(attrs)
    |> Repo.insert()
  end

  def update_probe(%EnvironmentProbe{} = probe, attrs) do
    probe
    |> EnvironmentProbe.changeset(attrs)
    |> Repo.update()
  end

  def run_probe_checks do
    now = DateTime.utc_now()

    from(p in EnvironmentProbe,
      where: p.status == "pending" and p.next_check_at < ^now
    )
    |> Repo.all()
    |> Enum.each(fn probe ->
      update_probe(probe, %{
        status: "checking",
        last_checked_at: now
      })
    end)
  end

  # --- Execution Workspace Policies ---

  def list_policies(project_id) do
    from(p in ExecutionWorkspacePolicy, where: p.project_id == ^project_id)
    |> Repo.all()
  end

  def get_policy!(id), do: Repo.get!(ExecutionWorkspacePolicy, id)

  def get_policy(id) do
    case Repo.get(ExecutionWorkspacePolicy, id) do
      nil -> {:error, :not_found}
      policy -> {:ok, policy}
    end
  end

  def get_policy_for_project(project_id) do
    case Repo.get_by(ExecutionWorkspacePolicy, project_id: project_id) do
      nil -> {:error, :not_found}
      policy -> {:ok, policy}
    end
  end

  def create_policy(attrs \\ %{}) do
    %ExecutionWorkspacePolicy{}
    |> ExecutionWorkspacePolicy.changeset(attrs)
    |> Repo.insert()
  end

  def update_policy(%ExecutionWorkspacePolicy{} = policy, attrs) do
    policy
    |> ExecutionWorkspacePolicy.changeset(attrs)
    |> Repo.update()
  end

  def delete_policy(%ExecutionWorkspacePolicy{} = policy) do
    Repo.delete(policy)
  end

  def check_policy_limits(policy, project_id) do
    active_count =
      from(ew in ExecutionWorkspace,
        where: ew.project_id == ^project_id and ew.status == "open"
      )
      |> Repo.aggregate(:count, :id)

    if active_count < policy.max_concurrent_workspaces do
      :ok
    else
      {:error, :concurrency_limit_reached}
    end
  end

  def cleanup_idle_workspaces do
    now = DateTime.utc_now()

    from(p in ExecutionWorkspacePolicy, where: p.auto_cleanup == true)
    |> Repo.all()
    |> Enum.each(fn policy ->
      threshold = DateTime.add(now, -policy.max_idle_minutes * 60, :second)

      from(ew in ExecutionWorkspace,
        where:
          ew.project_id == ^policy.project_id and
            ew.status == "open" and
            ew.last_used_at < ^threshold
      )
      |> Repo.update_all(
        set: [status: "closed", closed_at: now, cleanup_reason: "idle", updated_at: now]
      )
    end)
  end
end
