defmodule CymphoWeb.FallbackController do
  use CymphoWeb, :controller

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(json: CymphoWeb.ErrorJSON)
    |> render(:"404")
  end

  def call(conn, {:error, :forbidden}) do
    conn
    |> put_status(:forbidden)
    |> put_view(json: CymphoWeb.ErrorJSON)
    |> render(:error, message: "Forbidden")
  end

  def call(conn, {:error, :unauthorized}) do
    conn
    |> put_status(:unauthorized)
    |> put_view(json: CymphoWeb.ErrorJSON)
    |> render(:error, message: "Unauthorized")
  end

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: CymphoWeb.ErrorJSON)
    |> render(:error, changeset: changeset)
  end

  def call(conn, {:error, :invalid_transition}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: CymphoWeb.ErrorJSON)
    |> render(:error, message: "Invalid state transition")
  end

  def call(conn, {:error, reason}) do
    conn
    |> put_status(:bad_request)
    |> put_view(json: CymphoWeb.ErrorJSON)
    |> render(:error, message: reason)
  end
end
