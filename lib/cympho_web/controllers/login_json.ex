defmodule CymphoWeb.LoginJSON do
  alias Cympho.Users.User

  def show(%{user: %User{} = user, company_id: company_id, token: token}) do
    %{
      data: data(user, company_id),
      token: token
    }
  end

  defp data(%User{} = user, company_id) do
    %{
      id: user.id,
      email: user.email,
      name: user.name,
      company_id: company_id,
      inserted_at: user.inserted_at,
      updated_at: user.updated_at
    }
  end
end
