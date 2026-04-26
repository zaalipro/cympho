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

  describe "handle_in ping" do
    test "replies with pong" do
      company_id = Ecto.UUID.generate()
      {:ok, socket} = connect_jwt(company_id, Ecto.UUID.generate())

      {:ok, _, socket} =
        subscribe_and_join(socket, CymphoWeb.CompanyChannel, "company:#{company_id}")

      ref = push(socket, "ping", %{})
      assert_reply ref, :ok, %{pong: true}
    end
  end

  describe "event replay" do
    test "replays missed events when joining with last_event_id" do
      company_id = Ecto.UUID.generate()
      topic = "company:#{company_id}"

      Cympho.EventStore.append(topic, %{action: "create"})
      event_id = Cympho.EventStore.append(topic, %{action: "update"})
      Cympho.EventStore.append(topic, %{action: "delete"})

      {:ok, socket} = connect_jwt(company_id, Ecto.UUID.generate())

      {:ok, _, _socket} =
        subscribe_and_join(
          socket,
          CymphoWeb.CompanyChannel,
          topic,
          %{"last_event_id" => event_id}
        )

      assert_push "replay", %{payload: %{action: "delete"}}, 500
    end

    test "does not replay when no last_event_id provided" do
      company_id = Ecto.UUID.generate()
      topic = "company:#{company_id}"

      Cympho.EventStore.append(topic, %{action: "create"})

      {:ok, socket} = connect_jwt(company_id, Ecto.UUID.generate())

      {:ok, _, _socket} =
        subscribe_and_join(socket, CymphoWeb.CompanyChannel, topic)

      refute_push "replay", _
    end

    test "pushes replay_expired when window has expired" do
      company_id = Ecto.UUID.generate()
      topic = "company:#{company_id}"

      # Append one event to establish a min_id, then use an older id to trigger expiry
      Cympho.EventStore.append(topic, %{action: "create"})
      Cympho.EventStore.append(topic, %{action: "update"})

      {:ok, socket} = connect_jwt(company_id, Ecto.UUID.generate())

      {:ok, _, _socket} =
        subscribe_and_join(
          socket,
          CymphoWeb.CompanyChannel,
          topic,
          %{"last_event_id" => 0}
        )

      assert_push "replay_expired", %{reason: "replay_window_expired"}, 500
    end
  end
end
