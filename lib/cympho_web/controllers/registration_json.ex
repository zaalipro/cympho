defmodule CymphoWeb.RegistrationJSON do
  alias Cympho.Users.User

  def show(%{user: %User{} = user}) do
    %{data: data(user)}
  end

  def error(%{changeset: changeset}) do
    %{errors: transform_errors(changeset)}
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

  defp transform_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
