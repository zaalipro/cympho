defmodule Cympho.CompaniesOwnerConcurrencyTest do
  use ExUnit.Case, async: false

  alias Cympho.Companies
  alias Cympho.Repo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)
    unique = System.unique_integer([:positive])

    {:ok, company} =
      Companies.create_company(%{name: "Owner race #{unique}", slug: "owner-race-#{unique}"})

    users =
      for suffix <- ~w(a b) do
        {:ok, user} =
          Cympho.Users.create_user(%{
            name: "Owner #{suffix}",
            email: "owner-race-#{suffix}-#{unique}@example.com",
            password: "password1234"
          })

        {:ok, membership} =
          Companies.create_membership(%{
            company_id: company.id,
            user_id: user.id,
            role: "owner"
          })

        {user, membership}
      end

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Repo.delete!(company)
        for {user, _membership} <- users, do: Repo.delete!(user)
      end)
    end)

    %{company: company, users: users}
  end

  test "separate database transactions cannot remove both owners", %{
    company: company,
    users: users
  } do
    start = make_ref()

    tasks =
      for {user, membership} <- users do
        Task.async(fn ->
          :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo, sandbox: false)

          try do
            receive do
              ^start -> Companies.delete_membership_for_actor(user.id, company.id, membership.id)
            end
          after
            :ok = Ecto.Adapters.SQL.Sandbox.checkin(Repo)
          end
        end)
      end

    Enum.each(tasks, &send(&1.pid, start))
    results = Enum.map(tasks, &Task.await(&1, 10_000))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &match?({:error, :last_owner}, &1)) == 1
    assert Enum.count(Companies.list_memberships(company.id), &(&1.role == "owner")) == 1
  end
end
