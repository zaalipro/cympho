defmodule CymphoWeb.Live.CompanyRBAC do
  @moduledoc "Server-side company-role enforcement for LiveView events."

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4, put_flash: 3, redirect: 2]

  alias Cympho.CompanyRBAC
  alias Cympho.Companies

  @personal_views [
    CymphoWeb.SettingsLive.Profile,
    CymphoWeb.SettingsLive.Appearance,
    CymphoWeb.SettingsLive.Index
  ]

  # These views already re-read membership on every sensitive event so an
  # open socket honors demotion/removal immediately. Keep that stronger check
  # authoritative instead of replacing its target-aware denial behavior.
  @self_authorizing_views [
    CymphoWeb.CompanyLive.Index,
    CymphoWeb.CompanyLive.Show,
    CymphoWeb.PluginLive.Edit,
    CymphoWeb.PluginLive.Index,
    CymphoWeb.PluginLive.New,
    CymphoWeb.PluginLive.Show,
    CymphoWeb.PluginMarketplaceLive.Index,
    CymphoWeb.ProxyLive.Index,
    CymphoWeb.SecretsLive.Index
  ]

  @owner_events ~w(delete_company)

  @dashboard_runtime_events ~w(low_power_company pause_company resume_company)

  @view_admin_events %{
    CymphoWeb.SettingsLive.Integrations =>
      ~w(create_mcp_key disconnect_agrenting save_agrenting test_agrenting),
    CymphoWeb.AgentLive.New => ~w(save),
    CymphoWeb.AgentLive.Remote => ~w(hire_agent),
    CymphoWeb.AgentLive.Show => ~w(
        config_save delete_file new_file pause_agent restore_config_revision resume_agent
        run_heartbeat save_file test_adapter toggle_skill
      ),
    CymphoWeb.ExecutionPolicyLive.New => ~w(save),
    CymphoWeb.ExecutionPolicyLive.Edit => ~w(save)
  }

  @view_write_events %{
    CymphoWeb.InboxLive.Index => ~w(archive dismiss mark_read mark_unread_read restore)
  }

  @admin_events ~w(
    archive archive_routine delete delete_agent delete_comment delete_env
    delete_execution_policy delete_file delete_goal delete_issue delete_label delete_membership
    delete_project delete_routine delete_workspace disconnect_agrenting install kill_session
    low_power_company pause_agent pause_company pause_issue_runtime recover_stale_runs release_issue
    restore restore_config_revision restore_revision resume_agent resume_company resume_issue_runtime
    rotate terminate_agent uninstall
  )

  @write_events ~w(
    accept_owner_verification add_comment add_env apply_instruction_patch apply_prompt_plan
    apply_recommended_instruction_patches apply_runtime_preset approve approve_approval
    approve_review approve_spec assign_issue attach_work_product cast_vote clear_github_pr_number
    clear_recent_searches clear_stale_comment_wakes config_save create_ceo_flow_smoke_issue
    create_improvement create_label create_launch_item create_mcp_key create_schedule_trigger
    create_workspace delete_budget deny deny_approval dismiss dismiss_budget_incident
    draft_delivery_brief_repair draft_owner_brief_repair hire_agent install link_issue_to_goal link_telegram low_power_company
    manual_run mark_read mark_unread_read new_file pause_agent pause_company pause_issue_runtime
    pause_routine prepare_relaunch prioritize_delegated_work prioritize_dispatch
    queue_contract_nudge queue_review_nudge recover_stale_runs release_issue request_changes
    request_owner_revision reset resolve_interaction resolve_review_gate respond_questions
    resume_agent resume_company resume_issue_runtime resume_routine run_heartbeat save save_agrenting
    save_config save_description save_file save_title send_test_heartbeat set_github_pr_url spawn
    spawn_agent start_autonomous_company start_import submit_comment test test_adapter test_agrenting
    test_health test_webhook toggle_blocked toggle_channel toggle_event toggle_permission
    toggle_plugin toggle_role_overrides toggle_skill transition_issue unassign_issue update_github_pr_number
    update_label update_owner update_pause_reason update_priority update_status update_webhook_url
    update_work_mode verify_integrity verify_telegram write_prompt
  )

  def on_mount(:default, _params, _session, socket) do
    role = current_role(socket)

    socket =
      socket
      |> assign(:current_company_role, role)
      |> assign(:company_writable, CompanyRBAC.allowed?(role, :write))
      |> assign(:company_admin, CompanyRBAC.allowed?(role, :admin))
      |> attach_hook(:company_rbac, :handle_event, &authorize_event/3)
      |> attach_hook(:company_rbac_params, :handle_params, &authorize_params/3)
      |> attach_hook(:company_rbac_info, :handle_info, &authorize_info/2)

    {:cont, socket}
  end

  def event_access(event) when event in @owner_events, do: :owner
  def event_access(event) when event in @admin_events, do: :admin
  def event_access(event) when event in @write_events, do: :write

  def event_access(event) do
    if read_event?(event), do: :read, else: :write
  end

  def event_access(event, %{view: view}) do
    cond do
      event in Map.get(@view_admin_events, view, []) -> :admin
      event in Map.get(@view_write_events, view, []) -> :write
      true -> event_access(event)
    end
  end

  def event_access(event, _socket), do: event_access(event)

  defp authorize_event(event, _params, socket) do
    access = event_access(event, socket)
    {role, socket} = refresh_role(socket)

    cond do
      stale_membership?(role, socket) ->
        {:halt, membership_redirect(socket)}

      bypass_event_policy?(event, socket) or CompanyRBAC.allowed?(role, access) ->
        {:cont, socket}

      true ->
        {:halt, put_flash(socket, :error, "Your company role does not allow that action.")}
    end
  end

  defp authorize_params(_params, _url, socket), do: authorize_lifecycle(socket)
  defp authorize_info(_message, socket), do: authorize_lifecycle(socket)

  defp authorize_lifecycle(socket) do
    {role, socket} = refresh_role(socket)

    if stale_membership?(role, socket) do
      {:halt, membership_redirect(socket)}
    else
      {:cont, socket}
    end
  end

  defp refresh_role(socket) do
    role = current_role(socket)

    socket =
      socket
      |> assign(:current_company_role, role)
      |> assign(:company_writable, CompanyRBAC.allowed?(role, :write))
      |> assign(:company_admin, CompanyRBAC.allowed?(role, :admin))

    {role, socket}
  end

  defp stale_membership?(nil, socket) do
    match?(
      {%{id: user_id}, %{id: company_id}} when is_binary(user_id) and is_binary(company_id),
      {socket.assigns[:current_user], socket.assigns[:current_company]}
    )
  end

  defp stale_membership?(_role, _socket), do: false

  defp membership_redirect(socket) do
    socket
    |> put_flash(:error, "You no longer have access to that company.")
    |> redirect(to: "/")
  end

  defp current_role(socket) do
    case {socket.assigns[:current_user], socket.assigns[:current_company]} do
      {%{id: user_id}, %{id: company_id}} -> Companies.get_role(user_id, company_id)
      _ -> nil
    end
  end

  defp personal_view?(%{view: view}), do: view in @personal_views
  defp personal_view?(_socket), do: false

  defp self_authorizing_view?(%{view: view}), do: view in @self_authorizing_views
  defp self_authorizing_view?(_socket), do: false

  defp dashboard_runtime_event?(event, %{view: CymphoWeb.DashboardLive.Index}),
    do: event in @dashboard_runtime_events

  defp dashboard_runtime_event?(_event, _socket), do: false

  defp bypass_event_policy?(event, socket) do
    personal_view?(socket) or self_authorizing_view?(socket) or
      dashboard_runtime_event?(event, socket)
  end

  # Unknown events fail closed for viewers. These are navigation, filtering,
  # form-only, preview, or export interactions that do not persist company data.
  defp read_event?(event) do
    event in ~w(
      adapter_changed add_env_row cancel_comment cancel_edit cancel_editing cancel_pr_form
      cancel_upload cancel_work_product change_days change_page change_tab clear_filters
      close_agent_panel close_prompt_preview close_prompt_receipt close_trace_details
      combobox_assignee combobox_label combobox_priority combobox_project combobox_status
      combobox_work_mode dismiss_transition_blocker download edit_label export_csv export_json
      export_svg filter filter_assignee filter_blueprints filter_company filter_label
      filter_priority filter_project filter_search filter_status filter_triage generate_export
      hide_form hide_pause_modal hide_resume_modal hide_revision_diff hide_revisions hide_versions
      load_more new_file next-page next_step prev_step prevent preview preview_prompt_plan refresh
      remove_env_row search search_assignee select_agent select_file select_onboarding_path
      select_run select_runtime_profile select_trace set_slug_strategy set_tab set_timeline_filter
      show_create_form show_document_revisions show_edit_form show_form show_pause_modal
      show_resume_modal show_revision_diff show_versions start_editing switch_tab toggle_agent_panel
      toggle_column toggle_company_stats toggle_instructions_preview toggle_swimlanes toggle_trace
      update_company_form use_comment_template use_launch_scaffold validate validate_config
      validate_upload validate_work_product
    )
  end
end
