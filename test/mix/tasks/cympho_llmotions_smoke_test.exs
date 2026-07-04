defmodule Mix.Tasks.CymphoLlmotionsSmokeTest do
  use Cympho.DataCase, async: false

  import ExUnit.CaptureIO

  alias Cympho.Companies
  alias Cympho.Secrets
  alias Cympho.Workspaces

  setup do
    original_key = Application.get_env(:cympho, :encryption_key)
    Application.put_env(:cympho, :encryption_key, String.duplicate("m", 32))

    on_exit(fn ->
      Mix.Task.reenable("cympho.llmotions_smoke")

      if original_key do
        Application.put_env(:cympho, :encryption_key, original_key)
      else
        Application.delete_env(:cympho, :encryption_key)
      end
    end)
  end

  test "creates a smoke company without printing the supplied API key" do
    unique = System.unique_integer([:positive])
    company_name = "Mix LLMotions Smoke #{unique}"

    output =
      capture_io(fn ->
        Mix.Task.reenable("cympho.llmotions_smoke")

        Mix.Tasks.Cympho.LlmotionsSmoke.run([
          "--yes",
          "--company-name",
          company_name,
          "--issue-prefix",
          "MLT",
          "--api-key",
          "task-secret-value",
          "--model",
          "gemini-3.5-flash"
        ])
      end)

    assert output =~ "LLMotions smoke company ready"
    assert output =~ "gemini-3.5-flash"
    assert output =~ "Workspace:"
    assert output =~ File.cwd!()
    refute output =~ "task-secret-value"

    company =
      Companies.list_companies()
      |> Enum.find(&(&1.name == company_name))

    assert company

    assert {:ok, secret} =
             Secrets.get_secret_by_key(company.id, "LLMOTIONS_API_KEY", scope: "company")

    assert {:ok, "task-secret-value"} = Secrets.get_secret_value(secret.id)

    assert [%{cwd: cwd, is_primary: true}] =
             Workspaces.list_project_workspaces_for_company(company.id)

    assert cwd == File.cwd!()
  end
end
