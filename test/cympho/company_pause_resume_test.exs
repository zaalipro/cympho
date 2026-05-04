defmodule Cympho.CompanyPauseResumeTest do
  use Cympho.DataCase
  alias Cympho.Companies

  describe "pause_company/2" do
    test "pauses an active company" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Test Company",
          slug: "test-company"
        })

      assert company.status == "active"
      assert is_nil(company.paused_at)
      assert is_nil(company.paused_reason)

      {:ok, paused_company} =
        Companies.pause_company(company, "Manual pause for testing")

      assert paused_company.status == "paused"
      assert paused_company.paused_reason == "Manual pause for testing"
      assert paused_company.paused_at != nil
    end

    test "uses default reason when none provided" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Test Company",
          slug: "test-company"
        })

      {:ok, paused_company} = Companies.pause_company(company)

      assert paused_company.status == "paused"
      assert paused_company.paused_reason == "Paused from dashboard"
    end
  end

  describe "resume_company/1" do
    test "resumes a paused company" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Test Company",
          slug: "test-company"
        })

      {:ok, paused_company} =
        Companies.pause_company(company, "Test pause")

      assert paused_company.status == "paused"

      {:ok, resumed_company} = Companies.resume_company(paused_company)

      assert resumed_company.status == "active"
      assert is_nil(resumed_company.paused_at)
      assert is_nil(resumed_company.paused_reason)
    end
  end

  describe "active?/1" do
    test "returns true for active companies" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Test Company",
          slug: "test-company"
        })

      assert Companies.active?(company) == true
    end

    test "returns false for paused companies" do
      {:ok, company} =
        Companies.create_company(%{
          name: "Test Company",
          slug: "test-company"
        })

      {:ok, paused_company} = Companies.pause_company(company)

      assert Companies.active?(paused_company) == false
    end
  end
end
