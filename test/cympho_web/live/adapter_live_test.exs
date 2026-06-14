defmodule CymphoWeb.AdapterLiveTest do
  use CymphoWeb.LiveCase, async: true

  alias Cympho.Agents

  describe "Adapters index" do
    test "renders runtime readiness guidance before agents are assigned", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/settings/adapters")

      assert html =~ ~s(data-testid="adapter-runtime-readiness")
      assert html =~ "Adapter Status Overview"
      assert html =~ "Runtime readiness"
      assert html =~ "no agents are assigned to a runtime yet"
      assert html =~ "Add agent"
      assert html =~ "Secrets"
      assert html =~ "Healthy adapters"
      assert html =~ "Unavailable"
    end

    test "summarizes assigned adapter usage for the current company", %{
      conn: conn,
      current_company: company
    } do
      {:ok, _agent} =
        Agents.create_agent(%{
          name: "Adapter Live Agent",
          role: :engineer,
          company_id: company.id,
          adapter: :process
        })

      {:ok, _view, html} = live(conn, "/settings/adapters")

      assert html =~ "Runtime readiness"
      assert html =~ "Assigned agents"
      assert html =~ "1 adapters in use"
      assert html =~ "Operations"
    end

    test "invalid adapter health events do not crash the page", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/settings/adapters")

      html = render_click(view, "test_adapter", %{"key" => "definitely_not_registered"})

      assert html =~ "Unknown adapter"
      assert html =~ "Runtime readiness"
    end
  end
end
