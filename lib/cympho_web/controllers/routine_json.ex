defmodule CymphoWeb.RoutineJSON do
  alias Cympho.Routines.Routine

  def index(%{routines: routines}) do
    %{data: Enum.map(routines, &data/1)}
  end

  def show(%{routine: %Routine{} = routine}) do
    %{data: data(routine)}
  end

  defp data(%Routine{} = routine) do
    %{
      id: routine.id,
      name: routine.name,
      description: routine.description,
      status: routine.status,
      concurrency_policy: routine.concurrency_policy,
      catch_up_policy: routine.catch_up_policy,
      priority: routine.priority,
      agent_id: routine.agent_id,
      project_id: routine.project_id,
      inserted_at: routine.inserted_at,
      updated_at: routine.updated_at
    }
  end
end
