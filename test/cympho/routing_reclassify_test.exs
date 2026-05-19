defmodule Cympho.RoutingReclassifyTest do
  use Cympho.DataCase, async: false

  import Mock

  alias Cympho.Companies
  alias Cympho.Issues

  setup do
    {:ok, company} =
      Companies.create_company(%{
        name: "Reclassify Co #{System.unique_integer([:positive])}",
        slug: "reclassify-#{System.unique_integer([:positive])}"
      })

    prior_enabled = Application.get_env(:cympho, :llm_router_enabled?)
    prior_sync = Application.get_env(:cympho, :auto_ignite_sync)
    prior_key = Application.get_env(:cympho, :anthropic_api_key)

    Application.put_env(:cympho, :auto_ignite_sync, true)
    Application.put_env(:cympho, :llm_router_enabled?, false)

    on_exit(fn ->
      put_or_delete(:llm_router_enabled?, prior_enabled)
      put_or_delete(:auto_ignite_sync, prior_sync)
      put_or_delete(:anthropic_api_key, prior_key)
    end)

    %{company: company}
  end

  defp put_or_delete(key, nil), do: Application.delete_env(:cympho, key)
  defp put_or_delete(key, val), do: Application.put_env(:cympho, key, val)

  describe "reclassify on update_issue" do
    test "title change with prior source=llm triggers reclassification", %{company: company} do
      # Seed an issue whose monitor_state already records an LLM-derived
      # role. We bypass the create-time hook by keeping the LLM router
      # disabled and writing monitor_state directly via update_issue.
      {:ok, issue} =
        Issues.create_issue(%{
          title: "First title",
          description: "",
          company_id: company.id
        })

      {:ok, issue} =
        Issues.update_issue(issue, %{
          assigned_role: "engineer",
          monitor_state: %{
            "routing" => %{
              "source" => "llm",
              "classified_at" => "2026-05-19T00:00:00Z",
              "model" => "claude-haiku-4-5-20251001"
            }
          }
        })

      # Now re-enable the router and stub Finch to return a different role.
      Application.put_env(:cympho, :llm_router_enabled?, true)
      Application.put_env(:cympho, :anthropic_api_key, "test")
      Application.put_env(:cympho, :auto_ignite_sync, true)

      body =
        Jason.encode!(%{
          "content" => [%{"type" => "text", "text" => "cto"}]
        })

      with_mock Finch,
        build: fn _, _, _, _ -> :req end,
        request: fn :req, _, _ ->
          {:ok, %Finch.Response{status: 200, body: body, headers: []}}
        end do
        {:ok, updated} = Issues.update_issue(issue, %{title: "Rewrite auth infra"})

        # Reclassify runs under Task.Supervisor — give it a beat to land.
        wait_for_role(updated.id, "cto", 50)

        reloaded = Issues.get_issue!(updated.id)
        assert reloaded.assigned_role == "cto"
        assert reloaded.monitor_state["routing"]["source"] == "llm"
      end
    end

    test "title change with prior source != llm does NOT trigger reclassification",
         %{company: company} do
      {:ok, issue} =
        Issues.create_issue(%{
          title: "First",
          description: "",
          company_id: company.id
        })

      # Manually pinned role with no routing metadata.
      {:ok, issue} = Issues.update_issue(issue, %{assigned_role: "engineer"})

      Application.put_env(:cympho, :llm_router_enabled?, true)
      Application.put_env(:cympho, :anthropic_api_key, "test")

      with_mock Finch,
        build: fn _, _, _, _ ->
          flunk("Finch.build should not be called when prior source is not llm")
        end,
        request: fn _, _, _ ->
          flunk("Finch.request should not be called when prior source is not llm")
        end do
        {:ok, updated} = Issues.update_issue(issue, %{title: "Brand new title"})
        Process.sleep(30)
        reloaded = Issues.get_issue!(updated.id)
        assert reloaded.assigned_role == "engineer"
      end
    end
  end

  defp wait_for_role(id, expected, retries) when retries > 0 do
    case Issues.get_issue(id) do
      {:ok, %{assigned_role: ^expected}} ->
        :ok

      _ ->
        Process.sleep(20)
        wait_for_role(id, expected, retries - 1)
    end
  end

  defp wait_for_role(_id, _expected, 0), do: :timeout
end
