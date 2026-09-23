defmodule CymphoWeb.CompanyChannelTest do
  use CymphoWeb.ChannelCase

  alias Cympho.Companies

  describe "join company:<id>" do
    test "session join rechecks revoked membership on base and delegated topics" do
      unique = System.unique_integer([:positive])

      {:ok, company} =
        Companies.create_company(%{name: "Channel #{unique}", slug: "channel-#{unique}"})

      {:ok, user} =
        Cympho.Users.create_user(%{
          name: "Channel user",
          email: "channel-#{unique}@example.com",
          password: "password1234"
        })

      {:ok, membership} =
        Companies.create_membership(%{company_id: company.id, user_id: user.id, role: "member"})

      {:ok, socket} = connect_session(company.id, user.id)
      {:ok, _} = Companies.delete_membership(membership)

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(socket, CymphoWeb.CompanyChannel, "company:#{company.id}")

      assert {:error, %{reason: "unauthorized"}} =
               subscribe_and_join(
                 socket,
                 CymphoWeb.CompanyChannel,
                 "company:#{company.id}:activities"
               )
    end

    test "membership removal disconnects only that company socket" do
      unique = System.unique_integer([:positive])

      {:ok, company} =
        Companies.create_company(%{name: "Disconnect #{unique}", slug: "disconnect-#{unique}"})

      {:ok, other} =
        Companies.create_company(%{
          name: "Other disconnect #{unique}",
          slug: "other-disconnect-#{unique}"
        })

      {:ok, owner} =
        Cympho.Users.create_user(%{
          name: "Owner",
          email: "disconnect-owner-#{unique}@example.com",
          password: "password1234"
        })

      {:ok, target} =
        Cympho.Users.create_user(%{
          name: "Target",
          email: "disconnect-target-#{unique}@example.com",
          password: "password1234"
        })

      {:ok, _} =
        Companies.create_membership(%{company_id: company.id, user_id: owner.id, role: "owner"})

      {:ok, membership} =
        Companies.create_membership(%{company_id: company.id, user_id: target.id, role: "member"})

      {:ok, _} =
        Companies.create_membership(%{company_id: other.id, user_id: target.id, role: "member"})

      Phoenix.PubSub.subscribe(Cympho.PubSub, "socket:#{company.id}:#{target.id}")
      other_topic = "socket:#{other.id}:#{target.id}"
      Phoenix.PubSub.subscribe(Cympho.PubSub, other_topic)

      assert {:ok, _} = Companies.delete_membership_for_actor(owner.id, company.id, membership.id)
      assert_receive %Phoenix.Socket.Broadcast{topic: topic, event: "disconnect"}
      assert topic == "socket:#{company.id}:#{target.id}"
      refute_receive %Phoenix.Socket.Broadcast{topic: ^other_topic, event: "disconnect"}, 100
    end

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
