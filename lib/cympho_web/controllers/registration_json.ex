defmodule CymphoWeb.RegistrationJSON do
  def show(%{user: user}) do
    %{
      data: %{
        id: user.id,
        email: user.email,
        name: user.name
      }
    }
  end

  def error(%{changeset: changeset}) do
    %{
      errors: Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
        Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)
    }
  end
end