defmodule Cympho.RoutingDisabledTest do
  use Cympho.DataCase, async: false

  import Mock

  alias Cympho.Companies
  alias Cympho.Issues

  setup do
    {:ok, company} =
      Companies.create_company(%{
        name: "Disabled Co #{System.unique_integer([:positive])}",
        slug: "disabled-#{System.unique_integer([:positive])}"
      })

    prior_enabled = Application.get_env(:cympho, :llm_router_enabled?)
    prior_sync = Application.get_env(:cympho, :auto_ignite_sync)

    Application.put_env(:cympho, :auto_ignite_sync, true)

    on_exit(fn ->
      put_or_delete(:llm_router_enabled?, prior_enabled)
      put_or_delete(:auto_ignite_sync, prior_sync)
    end)

    %{company: company}
  end

  defp put_or_delete(key, nil), do: Application.delete_env(:cympho, key)
  defp put_or_delete(key, val), do: Application.put_env(:cympho, key, val)

  test "no Finch call is made when :llm_router_enabled? is false", %{company: company} do
    Application.put_env(:cympho, :llm_router_enabled?, false)

    with_mock Finch,
      build: fn _, _, _, _ ->
        flunk("Finch.build should not be called when router is disabled")
      end,
      request: fn _, _, _ ->
        flunk("Finch.request should not be called when router is disabled")
      end do
      {:ok, issue} =
        Issues.create_issue(%{
          title: "Fix flaky CI build",
          description: "Tests are timing out",
          company_id: company.id
        })

      # `assigned_role` stays blank — keyword router will resolve it at
      # dispatch time, no network call performed.
      assert is_nil(issue.assigned_role) or issue.assigned_role == ""
    end
  end

  test "no Finch call is made when no API key is configured", %{company: company} do
    Application.put_env(:cympho, :llm_router_enabled?, true)
    prior_key = Application.get_env(:cympho, :anthropic_api_key)
    prior_env_key = System.get_env("ANTHROPIC_API_KEY")
    Application.delete_env(:cympho, :anthropic_api_key)
    System.delete_env("ANTHROPIC_API_KEY")

    on_exit(fn ->
      put_or_delete(:anthropic_api_key, prior_key)
      if prior_env_key, do: System.put_env("ANTHROPIC_API_KEY", prior_env_key)
    end)

    with_mock Finch,
      build: fn _, _, _, _ -> flunk("Finch.build should not be called") end,
      request: fn _, _, _ -> flunk("Finch.request should not be called") end do
      {:ok, issue} =
        Issues.create_issue(%{
          title: "Add a new feature",
          description: "",
          company_id: company.id
        })

      assert is_nil(issue.assigned_role) or issue.assigned_role == ""
    end
  end
end
