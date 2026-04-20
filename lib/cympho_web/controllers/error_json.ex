defmodule CymphoWeb.ErrorJSON do
  def render(template, %{message: message}) do
    %{errors: %{detail: message}}
  end

  def render(template, %{changeset: changeset}) do
    %{
      errors:
        Ecto.Changeset.traverse_errors(changeset, &translate_error/1)
        |> Map.new()
    }
  end

  def render(template, _assigns) do
    %{errors: %{detail: Phoenix.Controller.status_message_from_template(template)}}
  end

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end
end
