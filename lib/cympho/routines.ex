defmodule Cympho.Routines do
  import Ecto.Query, warn: false
  alias Cympho.Repo
  alias Cympho.Routines.Routine

  def list_routines do
    Repo.all(from r in Routine, order_by: [desc: r.inserted_at])
  end

  def list_routines_by_status(status) when is_atom(status) do
    Repo.all(from r in Routine, where: r.status == ^status, order_by: [desc: r.inserted_at])
  end

  def get_routine!(id), do: Repo.get!(Routine, id)

  def get_routine(id) do
    case Repo.get(Routine, id) do
      nil -> {:error, :not_found}
      routine -> {:ok, routine}
    end
  end

  def create_routine(attrs \\ %{}) do
    %Routine{}
    |> Routine.changeset(attrs)
    |> Repo.insert()
  end

  def update_routine(%Routine{} = routine, attrs) do
    routine
    |> Routine.changeset(attrs)
    |> Repo.update()
  end

  def pause_routine(%Routine{status: :active} = routine) do
<<<<<<< HEAD
    routine
    |> Routine.changeset(%{status: :paused})
    |> Repo.update()
  end

  def pause_routine(%Routine{}) do
    {:error, :invalid_transition}
  end

  def resume_routine(%Routine{status: :paused} = routine) do
    routine
    |> Routine.changeset(%{status: :active})
    |> Repo.update()
  end

  def resume_routine(%Routine{}) do
    {:error, :invalid_transition}
  end

  def archive_routine(%Routine{status: status} = routine) when status in [:active, :paused] do
    routine
    |> Routine.changeset(%{status: :archived})
    |> Repo.update()
  end

  def archive_routine(%Routine{status: :archived}) do
    {:error, :invalid_transition}
  end

  def delete_routine(%Routine{} = routine) do
    Repo.delete(routine)
  end
=======
    routine |> Routine.changeset(%{status: :paused}) |> Repo.update()
  end
  def pause_routine(%Routine{}), do: {:error, :invalid_transition}

  def resume_routine(%Routine{status: :paused} = routine) do
    routine |> Routine.changeset(%{status: :active}) |> Repo.update()
  end
  def resume_routine(%Routine{}), do: {:error, :invalid_transition}

  def archive_routine(%Routine{status: status} = routine) when status in [:active, :paused] do
    routine |> Routine.changeset(%{status: :archived}) |> Repo.update()
  end
  def archive_routine(%Routine{status: :archived}), do: {:error, :invalid_transition}

  def delete_routine(%Routine{} = routine), do: Repo.delete(routine)
>>>>>>> origin/LLM-341/routine-triggers

  def change_routine(%Routine{} = routine, attrs \\ %{}) do
    Routine.changeset(routine, attrs)
  end
end
