defmodule Cympho.Companies.ImportDecodeAdmissionTest do
  use ExUnit.Case, async: true

  alias Cympho.Companies.ImportDecodeAdmission

  setup do
    limiter = start_supervised!({ImportDecodeAdmission, name: nil})
    {:ok, limiter: limiter}
  end

  test "fails fast while held and grants the slot after release", %{limiter: limiter} do
    assert {:ok, token} = ImportDecodeAdmission.checkout(limiter)

    task = Task.async(fn -> ImportDecodeAdmission.checkout(limiter) end)
    assert Task.await(task) == {:error, :busy}

    assert :ok = ImportDecodeAdmission.release(token, limiter)

    task =
      Task.async(fn ->
        {:ok, next_token} = ImportDecodeAdmission.checkout(limiter)
        ImportDecodeAdmission.release(next_token, limiter)
      end)

    assert Task.await(task) == :ok
  end

  test "reclaims the slot when its holder exits", %{limiter: limiter} do
    holder =
      spawn(fn ->
        {:ok, _token} = ImportDecodeAdmission.checkout(limiter)
        send(self(), :unreachable)
      end)

    monitor = Process.monitor(holder)
    assert_receive {:DOWN, ^monitor, :process, ^holder, :normal}

    assert eventually(fn ->
             case ImportDecodeAdmission.checkout(limiter) do
               {:ok, token} ->
                 ImportDecodeAdmission.release(token, limiter) == :ok

               {:error, :busy} ->
                 false
             end
           end)
  end

  test "a different process or stale token cannot release the holder's slot", %{limiter: limiter} do
    assert {:ok, token} = ImportDecodeAdmission.checkout(limiter)

    assert :ok =
             Task.async(fn -> ImportDecodeAdmission.release(token, limiter) end)
             |> Task.await()

    assert {:error, :busy} = ImportDecodeAdmission.checkout(limiter)
    assert :ok = ImportDecodeAdmission.release(make_ref(), limiter)
    assert {:error, :busy} = ImportDecodeAdmission.checkout(limiter)

    assert :ok = ImportDecodeAdmission.release(token, limiter)
    assert {:ok, next_token} = ImportDecodeAdmission.checkout(limiter)
    assert :ok = ImportDecodeAdmission.release(next_token, limiter)
  end

  defp eventually(assertion, attempts \\ 20)

  defp eventually(assertion, attempts) when attempts > 0 do
    if assertion.() do
      true
    else
      Process.sleep(5)
      eventually(assertion, attempts - 1)
    end
  end

  defp eventually(_assertion, 0), do: false
end
