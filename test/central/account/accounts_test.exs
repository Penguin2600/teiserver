defmodule Central.AccountTest do
  use Central.DataCase

  alias Central.Account
  alias Central.Account.AccountTestLib

  describe "users" do
    alias Central.Account.User

    @valid_attrs %{
      colour: "some colour",
      icon: "fa-regular fa-home",
      name: "some name",
      permissions: [],
      email: "AnEmailAddress@email.com",
      password: "some password"
    }
    @update_attrs %{
      colour: "some updated colour",
      icon: "fa-solid fa-wrench",
      permissions: [],
      name: "some updated name",
      email: "some updated email",
      password: "some updated password"
    }
    @invalid_attrs %{
      colour: nil,
      icon: nil,
      name: nil,
      permissions: nil,
      email: nil,
      password: nil
    }

    test "list_users/0 returns users" do
      assert Account.list_users() != []
    end

    test "get_user!/1 returns the user with given id" do
      user = AccountTestLib.user_fixture()
      assert Account.get_user!(user.id) == user
    end

    test "create_user/1 with valid data creates a user" do
      assert {:ok, %User{} = user} = Account.create_user(@valid_attrs)
      assert user.colour == "some colour"
      assert user.icon == "fa-regular fa-home"
      assert user.name == "some name"
      assert user.permissions == []
      assert user.name == "some name"
    end

    test "get_user_by_email/1 returns the user with the given email" do
      user = AccountTestLib.user_fixture()
      assert Account.get_user_by_email(user.email) == user
    end

    test "get_user_by_email/1 returns the user with given email in a case-insenitive way" do
      assert {:ok, %User{} = user} = Account.create_user(@valid_attrs)
      assert user.email == "AnEmailAddress@email.com"
      assert Account.get_user_by_email("anemailaddress@email.com") == user
      assert Account.get_user_by_email("AnemailaddreSS@email.com") == user
      assert Account.get_user_by_email("AnEmailAddress@email.com") == user
    end

    test "create_user/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Account.create_user(@invalid_attrs)
    end

    test "update_user/2 with valid data updates the user" do
      user = AccountTestLib.user_fixture()
      assert {:ok, %User{} = user} = Account.update_user(user, @update_attrs)
      assert user.colour == "some updated colour"
      assert user.icon == "fa-solid fa-wrench"
      assert user.name == "some updated name"
      assert user.permissions == []
      assert user.name == "some updated name"
    end

    test "update_user/2 with invalid data returns error changeset" do
      user = AccountTestLib.user_fixture()
      assert {:error, %Ecto.Changeset{}} = Account.update_user(user, @invalid_attrs)
      assert user == Account.get_user!(user.id)
    end

    # test "delete_user/1 deletes the user" do
    #   user = AccountTestLib.user_fixture()
    #   assert {:ok, %User{}} = Account.delete_user(user)
    #   assert_raise Ecto.NoResultsError, fn -> Account.get_user!(user.id) end
    # end

    test "change_user/1 returns a user changeset" do
      user = AccountTestLib.user_fixture()
      assert %Ecto.Changeset{} = Account.change_user(user)
    end
  end

  describe "groups" do
    alias Central.Account.Group

    @valid_attrs %{
      "colour" => "some colour",
      "icon" => "fa-regular fa-home",
      "name" => "some name",
      "data" => %{},
      "active" => true,
      "group_type" => "",
      "see_group" => false,
      "see_members" => false,
      "invite_members" => false,
      "self_add_members" => false,
      "children_cache" => [],
      "supers_cache" => []
    }
    @update_attrs %{
      "colour" => "some updated colour",
      "icon" => "fa-solid fa-wrench",
      "name" => "some updated name",
      "data" => %{},
      "active" => false,
      "group_type" => "",
      "see_group" => true,
      "see_members" => true,
      "invite_members" => true,
      "self_add_members" => true,
      "children_cache" => [],
      "supers_cache" => []
    }
    @invalid_attrs %{
      "colour" => nil,
      "icon" => nil,
      "name" => nil,
      "data" => nil,
      "active" => nil,
      "group_type" => nil,
      "see_group" => nil,
      "see_members" => nil,
      "invite_members" => nil,
      "self_add_members" => nil,
      "children_cache" => nil,
      "supers_cache" => nil
    }

    def group_fixture(attrs \\ %{}) do
      {:ok, group} =
        attrs
        |> Enum.into(@valid_attrs)
        |> Account.create_group()

      group
    end

    test "list_groups/0 returns groups" do
      assert Account.list_groups() != []
    end

    test "get_group!/1 returns the group with given id" do
      group = group_fixture()
      assert Account.get_group!(group.id) == group
    end

    test "create_group/1 with valid data creates a group" do
      assert {:ok, %Group{} = group} = Account.create_group(@valid_attrs)
      assert group.colour == "some colour"
      assert group.icon == "fa-regular fa-home"
      assert group.name == "some name"
    end

    test "create_group/1 with invalid data returns error changeset" do
      assert {:error, %Ecto.Changeset{}} = Account.create_group(@invalid_attrs)
    end

    test "update_group/2 with valid data updates the group" do
      group = group_fixture()
      assert {:ok, %Group{} = group} = Account.update_group(group, @update_attrs)
      assert group.colour == "some updated colour"
      assert group.icon == "fa-solid fa-wrench"
      assert group.name == "some updated name"
    end

    test "update_group/2 with invalid data returns error changeset" do
      group = group_fixture()
      assert {:error, %Ecto.Changeset{}} = Account.update_group(group, @invalid_attrs)
      assert group == Account.get_group!(group.id)
    end

    test "delete_group/1 deletes the group" do
      group = group_fixture()
      assert {:ok, %Group{}} = Account.delete_group(group)
      assert_raise Ecto.NoResultsError, fn -> Account.get_group!(group.id) end
    end

    test "change_group/1 returns a group changeset" do
      group = group_fixture()
      assert %Ecto.Changeset{} = Account.change_group(group)
    end
  end
end
