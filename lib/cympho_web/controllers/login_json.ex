defmodule CymphoWeb.LoginJSON do
  alias Cympho.Users.User

  def show(%{user: %User{} = user, token: token}) do
    %{
      data: data(user),
      token: token
    }
  end

  defp data(%User{} = user) do
    %{
      id: user.id,
      email: user.email,
      name: user.name,
      company_id: user.company_id,
      inserted_at: user.inserted_at,
      updated_at: user.updated_at
    }
  end
end
