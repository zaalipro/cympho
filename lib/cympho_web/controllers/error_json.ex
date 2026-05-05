defmodule CymphoWeb.ErrorJSON do
  def render(_template, %{message: message}) do
    %{errors: %{detail: message}}
  end

  def render(_template, %{changeset: changeset}) do
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
    opts = Enum.map(opts, fn {k, v} -> {k, inspect_value(v)} end)

    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", value)
    end)
  end

  defp inspect_value(value) when is_binary(value), do: value
  defp inspect_value(value) when is_atom(value), do: to_string(value)
  defp inspect_value(value) when is_number(value), do: to_string(value)
  defp inspect_value(value), do: inspect(value)
end
