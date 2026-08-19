defmodule Cympho.CompanyRBACTest do
  use ExUnit.Case, async: true

  alias Cympho.CompanyRBAC

  test "role matrix is monotonic and viewers are read-only" do
    assert CompanyRBAC.allowed?("viewer", :read)
    refute CompanyRBAC.allowed?("viewer", :write)
    refute CompanyRBAC.allowed?("viewer", :admin)

    assert CompanyRBAC.allowed?("member", :write)
    refute CompanyRBAC.allowed?("member", :admin)

    assert CompanyRBAC.allowed?("admin", :admin)
    refute CompanyRBAC.allowed?("admin", :owner)

    assert CompanyRBAC.allowed?("owner", :owner)
    refute CompanyRBAC.allowed?(nil, :read)
  end
end
