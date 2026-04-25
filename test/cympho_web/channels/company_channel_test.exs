defmodule CymphoWeb.CompanyChannelTest do
  use CymphoWeb.ChannelCase

  describe "join company:<id>" do
    test "joins successfully when company_id matches socket" do
      company_id = Ecto.UUID.generate()
      {:ok, socket} = connect_jwt(company_id, Ecto.UUID.generate())

      assert {:ok, _reply, _socket} =
               subscribe_and_join(socket, CymphoWeb.CompanyChannel, "company:#{company_id}")
    end

    test "rejects when company_id does not match socket" do
      company_id = Ecto.UUID.generate()
      other_company_id = Ecto.UUID.generate()
      {:ok, socket} = connect_jwt(company_id, Ecto.UUID.generate())

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(socket, CymphoWeb.CompanyChannel, "company:#{other_company_id}")
    end
  end

  describe "join company:<id>:activities" do
    test "joins activities sub-topic when company_id matches" do
      company_id = Ecto.UUID.generate()
      {:ok, socket} = connect_jwt(company_id, Ecto.UUID.generate())

      assert {:ok, _reply, _socket} =
               subscribe_and_join(
                 socket,
                 CymphoWeb.CompanyChannel,
                 "company:#{company_id}:activities"
               )
    end

    test "rejects activities sub-topic when company_id does not match" do
      company_id = Ecto.UUID.generate()
      other_company_id = Ecto.UUID.generate()
      {:ok, socket} = connect_jwt(company_id, Ecto.UUID.generate())

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 socket,
                 CymphoWeb.CompanyChannel,
                 "company:#{other_company_id}:activities"
               )
    end
  end

  describe "join company:<id>:issue:<id>" do
    test "joins issue sub-topic when company_id matches" do
      company_id = Ecto.UUID.generate()
      issue_id = Ecto.UUID.generate()
      {:ok, socket} = connect_jwt(company_id, Ecto.UUID.generate())

      assert {:ok, _reply, _socket} =
               subscribe_and_join(
                 socket,
                 CymphoWeb.CompanyChannel,
                 "company:#{company_id}:issue:#{issue_id}"
               )
    end

    test "rejects issue sub-topic when company_id does not match" do
      company_id = Ecto.UUID.generate()
      other_company_id = Ecto.UUID.generate()
      issue_id = Ecto.UUID.generate()
      {:ok, socket} = connect_jwt(company_id, Ecto.UUID.generate())

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 socket,
                 CymphoWeb.CompanyChannel,
                 "company:#{other_company_id}:issue:#{issue_id}"
               )
    end
  end

  describe "handle_in ping" do
    test "replies with pong" do
      company_id = Ecto.UUID.generate()
      {:ok, socket} = connect_jwt(company_id, Ecto.UUID.generate())

      {:ok, _, socket} =
        subscribe_and_join(socket, CymphoWeb.CompanyChannel, "company:#{company_id}")

      ref = push(socket, "ping", %{})
      assert_reply ref, {:ok, %{pong: true}}
    end
  end
end
