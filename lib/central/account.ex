defmodule Central.Account do
  @moduledoc """
  The Account context.
  """

  import Ecto.Query, warn: false
  alias Central.Helpers.QueryHelpers
  alias Phoenix.PubSub
  alias Central.Repo
  alias Central.Types, as: T

  alias Argon2

  alias Central.Account.User
  alias Central.Account.UserLib
  import Teiserver.Logging.Helpers, only: [add_anonymous_audit_log: 3]

  @spec icon :: String.t()
  def icon, do: "fa-duotone fa-user-alt"

  defp user_query(args) do
    user_query(nil, args)
  end

  defp user_query(id, args) do
    UserLib.get_users()
    |> UserLib.search(%{id: id})
    |> UserLib.search(args[:search])
    |> UserLib.preload(args[:joins])
    |> UserLib.order(args[:order])
    |> QueryHelpers.select(args[:select])
  end

  @doc """
  Returns the list of users.

  ## Examples

      iex> list_users()
      [%User{}, ...]

  """
  def list_users(args \\ []) do
    user_query(args)
    |> QueryHelpers.limit_query(args[:limit] || 50)
    |> Repo.all()
  end

  @doc """
  Gets a single user.

  Raises `Ecto.NoResultsError` if the User does not exist.

  ## Examples

      iex> get_user!(123)
      %User{}

      iex> get_user!(456)
      ** (Ecto.NoResultsError)

  """
  @spec get_user!(Integer.t() | List.t()) :: User.t()
  @spec get_user!(Integer.t(), List.t()) :: User.t()
  def get_user!(id) when not is_list(id) do
    Central.cache_get_or_store(:account_user_cache_bang, id, fn ->
      user_query(id, [])
      |> QueryHelpers.limit_query(1)
      |> Repo.one!()
    end)
  end

  def get_user!(args) do
    user_query(nil, args)
    |> QueryHelpers.limit_query(args[:limit] || 1)
    |> Repo.one!()
  end

  def get_user!(id, args) do
    user_query(id, args)
    |> QueryHelpers.limit_query(args[:limit] || 1)
    |> Repo.one!()
  end

  @doc """
  Gets a single classname.

  Returns `nil` if the Classname does not exist.

  ## Examples

      iex> get_classname(123)
      %Classname{}

      iex> get_classname(456)
      nil

  """
  @spec get_user(Integer.t() | List.t()) :: User.t() | nil
  @spec get_user(Integer.t(), List.t()) :: User.t() | nil
  def get_user(id) when not is_list(id) do
    Central.cache_get_or_store(:account_user_cache, id, fn ->
      user_query(id, [])
      |> Repo.one()
    end)
  end

  def get_user(args) do
    user_query(nil, args)
    |> Repo.one()
  end

  def get_user(id, args) do
    user_query(id, args)
    |> Repo.one()
  end

  @spec get_user_by_name(String.t()) :: User.t() | nil
  def get_user_by_name(name) do
    UserLib.get_users()
    |> UserLib.search(%{name: String.trim(name)})
    |> Repo.one()
  end

  @spec get_user_by_email(String.t()) :: User.t() | nil
  def get_user_by_email(email) do
    UserLib.get_users()
    |> UserLib.search(%{email_lower: String.trim(email)})
    |> Repo.one()
  end

  def recache_user(nil), do: nil
  def recache_user(%User{} = user), do: recache_user(user.id)

  def recache_user(id) do
    Central.cache_delete(:account_user_cache, id)
    Central.cache_delete(:account_user_cache_bang, id)
    Central.cache_delete(:account_membership_cache, id)
    Central.cache_delete(:communication_user_notifications, id)
    Central.cache_delete(:config_user_cache, id)
  end

  def broadcast_create_user(u), do: broadcast_create_user(u, :create)

  def broadcast_create_user({:ok, user}, reason) do
    PubSub.broadcast(
      Central.PubSub,
      "account_hooks",
      {:account_hooks, :create_user, user, reason}
    )

    {:ok, user}
  end

  def broadcast_create_user(v, _), do: v

  def broadcast_update_user(u), do: broadcast_update_user(u, :update)

  def broadcast_update_user({:ok, user}, reason) do
    PubSub.broadcast(
      Central.PubSub,
      "account_hooks",
      {:account_hooks, :update_user, user, reason}
    )

    {:ok, user}
  end

  def broadcast_update_user(v, _), do: v

  @doc """
  Creates a user.

  ## Examples

      iex> create_user(%{field: value})
      {:ok, %User{}}

      iex> create_user(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_user(attrs \\ %{}) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
    |> broadcast_create_user
  end

  def self_create_user(attrs \\ %{}) do
    %User{}
    |> User.changeset(attrs, :self_create)
    |> Repo.insert()
    |> broadcast_create_user
  end

  def create_throwaway_user(attrs \\ %{}) do
    params =
      %{
        "name" => generate_throwaway_name(),
        "email" => "#{UUID.uuid1()}@throwaway",
        "password" => UUID.uuid1()
      }
      |> Central.Helpers.StylingHelper.random_styling()
      |> Map.merge(attrs)

    %User{}
    |> User.changeset(params)
    |> Repo.insert()
    |> broadcast_create_user
  end

  def merge_default_params(user_params) do
    Map.merge(
      %{
        "icon" => "fa-solid fa-" <> Central.Helpers.StylingHelper.random_icon(),
        "colour" => Central.Helpers.StylingHelper.random_colour()
      },
      user_params
    )
  end

  @doc """
  Updates a user.

  ## Examples

      iex> update_user(user, %{field: new_value})
      {:ok, %User{}}

      iex> update_user(user, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_user(%User{} = user, attrs, changeset_type \\ nil) do
    recache_user(user.id)

    user
    |> User.changeset(attrs, changeset_type)
    |> Repo.update()
    |> broadcast_update_user
  end

  # @doc """
  # Deletes a User.

  # ## Examples

  #     iex> delete_user(user)
  #     {:ok, %User{}}

  #     iex> delete_user(user)
  #     {:error, %Ecto.Changeset{}}

  # """
  # def delete_user(%User{} = user) do
  #   Repo.delete(user)
  # end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking user changes.

  ## Examples

      iex> change_user(user)
      %Ecto.Changeset{source: %User{}}

  """
  def change_user(%User{} = user) do
    User.changeset(user, %{})
  end

  def authenticate_user(conn, %User{} = user, plain_text_password) do
    if User.verify_password(plain_text_password, user.password) do
      {:ok, user}
    else
      # Authentication failure handler
      Teiserver.Account.spring_auth_check(conn, user, plain_text_password)
    end
  end

  def authenticate_user(_conn, "", _plain_text_password) do
    Argon2.no_user_verify()
    Argon2.no_user_verify()
    {:error, "Invalid credentials"}
  end

  def authenticate_user(_conn, _, "") do
    Argon2.no_user_verify()
    Argon2.no_user_verify()
    {:error, "Invalid credentials"}
  end

  def authenticate_user(conn, email, plain_text_password) do
    case get_user_by_email(email) do
      nil ->
        Argon2.no_user_verify()
        Argon2.no_user_verify()
        add_anonymous_audit_log(conn, "Account:Failed login", %{reason: "No user", email: email})
        {:error, "Invalid credentials"}

      user ->
        authenticate_user(conn, user, plain_text_password)
    end
  end

  def login_failure(conn, user) do
    add_anonymous_audit_log(conn, "Account:Failed login", %{
      reason: "Bad password",
      user_id: user.id,
      email: user.email
    })

    {:error, "Invalid credentials"}
  end

  def user_as_json(users) when is_list(users) do
    users
    |> Enum.map(&user_as_json/1)
  end

  def user_as_json(user) do
    %{
      id: user.id,
      name: user.name,
      email: user.email,
      icon: user.icon,
      colour: user.colour,
      html_label: "#{user.name} - #{user.email}",
      html_value: "##{user.id}, #{user.name}"
    }
  end

  alias Central.Account.{Group, GroupLib}

  defp group_query(args) do
    group_query(nil, args)
  end

  defp group_query(id, args) do
    GroupLib.get_groups()
    |> GroupLib.search(%{id: id})
    |> GroupLib.search(args[:search])
    |> GroupLib.preload(args[:joins])
    |> GroupLib.order(args[:order])
    |> QueryHelpers.select(args[:select])
  end

  @doc """
  Returns the list of groups.

  ## Examples

      iex> list_groups()
      [%Group{}, ...]

  """
  def list_groups(args \\ []) do
    group_query(args)
    |> QueryHelpers.limit_query(args[:limit] || 50)
    |> Repo.all()
  end

  @doc """
  Gets a single group.

  Raises `Ecto.NoResultsError` if the Group does not exist.

  ## Examples

      iex> get_group!(123)
      %Group{}

      iex> get_group!(456)
      ** (Ecto.NoResultsError)

  """
  def get_group!(id) when not is_list(id) do
    group_query(id, [])
    |> QueryHelpers.limit_query(1)
    |> Repo.one!()
  end

  def get_group!(args) do
    group_query(nil, args)
    |> QueryHelpers.limit_query(args[:limit] || 1)
    |> Repo.one!()
  end

  def get_group!(id, args) do
    group_query(id, args)
    |> QueryHelpers.limit_query(args[:limit] || 1)
    |> Repo.one!()
  end

  def get_group(id, args \\ []) when not is_list(id) do
    group_query(id, args)
    |> QueryHelpers.limit_query(args[:limit] || 1)
    |> Repo.one()
  end

  def create_group(attrs \\ %{}) do
    %Group{}
    |> Group.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a group.

  ## Examples

      iex> update_group(group, %{field: new_value})
      {:ok, %Group{}}

      iex> update_group(group, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_group(%Group{} = group, attrs) do
    group
    |> Group.changeset(attrs)
    |> Repo.update()
  end

  def update_group_non_admin(%Group{} = group, attrs) do
    group
    |> Group.non_admin_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a Group.

  ## Examples

      iex> delete_group(group)
      {:ok, %Group{}}

      iex> delete_group(group)
      {:error, %Ecto.Changeset{}}

  """
  def delete_group(%Group{} = group) do
    Repo.delete(group)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking group changes.

  ## Examples

      iex> change_group(group)
      %Ecto.Changeset{source: %Group{}}

  """
  def change_group(%Group{} = group) do
    Group.changeset(group, %{})
  end

  def group_as_json(groups) when is_list(groups) do
    groups
    |> Enum.map(&group_as_json/1)
  end

  def group_as_json(group) do
    %{
      id: group.id,
      name: group.name,
      icon: group.icon,
      colour: group.colour,
      html_label: "#{group.name}",
      html_value: "##{group.id} - #{group.name}"
    }
  end

  alias Central.Account.GroupMembership
  alias Central.Account.GroupMembershipLib

  def list_group_memberships([user_id: user_id] = args) do
    GroupMembershipLib.get_group_memberships()
    |> GroupMembershipLib.search(user_id: user_id)
    |> GroupMembershipLib.search(args)
    |> GroupMembershipLib.preload(args[:joins])
    |> QueryHelpers.select(args[:select])
    # |> QueryHelpers.limit_query(50)
    |> Repo.all()
  end

  def list_group_memberships_cache(user_id) do
    Central.cache_get_or_store(:account_membership_cache, user_id, fn ->
      query =
        from ugm in GroupMembership,
          join: ug in Group,
          on: ugm.group_id == ug.id,
          where: ugm.user_id == ^user_id,
          select: {ug.id, ug.children_cache}

      Repo.all(query)
      |> Enum.map(fn {g, gc} -> [g | gc] end)
      |> List.flatten()
      |> Enum.uniq()
    end)
  end

  @doc """
  Gets a single group_membership.

  Raises `Ecto.NoResultsError` if the GroupMembership does not exist.

  ## Examples

      iex> get_group_membership!(123)
      %GroupMembership{}

      iex> get_group_membership!(456)
      ** (Ecto.NoResultsError)

  """
  @spec get_group_membership!(T.user_id(), T.group_id()) :: GroupMembership.t()
  def get_group_membership!(user_id, group_id) do
    GroupMembershipLib.get_group_memberships()
    |> GroupMembershipLib.search(user_id: user_id, group_id: group_id)
    |> QueryHelpers.limit_query(1)
    |> Repo.one!()
  end

  @spec get_group_membership(T.user_id(), T.group_id()) :: GroupMembership.t() | nil
  def get_group_membership(user_id, group_id) do
    GroupMembershipLib.get_group_memberships()
    |> GroupMembershipLib.search(user_id: user_id, group_id: group_id)
    |> QueryHelpers.limit_query(1)
    |> Repo.one()
  end

  def create_group_membership(attrs \\ %{}) do
    r =
      %GroupMembership{}
      |> GroupMembership.changeset(attrs)
      |> Repo.insert()

    recache_user(attrs["user_id"])
    r
  end

  @doc """
  Updates a group_membership.

  ## Examples

      iex> update_group_membership(group_membership, %{field: new_value})
      {:ok, %GroupMembership{}}

      iex> update_group_membership(group_membership, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_group_membership(%GroupMembership{} = group_membership, attrs) do
    group_membership
    |> GroupMembership.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a GroupMembership.

  ## Examples

      iex> delete_group_membership(group_membership)
      {:ok, %GroupMembership{}}

      iex> delete_group_membership(group_membership)
      {:error, %Ecto.Changeset{}}

  """
  def delete_group_membership(%GroupMembership{} = group_membership) do
    recache_user(group_membership.user_id)
    Repo.delete(group_membership)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking group_membership changes.

  ## Examples

      iex> change_group_membership(group_membership)
      %Ecto.Changeset{source: %GroupMembership{}}

  """
  def change_group_membership(%GroupMembership{} = group_membership) do
    GroupMembership.changeset(group_membership, %{})
  end

  alias Central.Account.{GroupInvite, GroupInviteLib}

  @doc """
  Returns the list of group_invites.

  ## Examples

      iex> list_group_invites()
      [%Location{}, ...]

  """
  def list_group_invites_by_group(group_id, args \\ []) do
    GroupInviteLib.get_group_invites()
    |> GroupInviteLib.search(group_id: group_id)
    |> GroupInviteLib.search(args[:search])
    |> GroupInviteLib.preload(args[:joins])
    # |> GroupInviteLib.order_by(args[:order_by])
    |> QueryHelpers.select(args[:select])
    |> Repo.all()
  end

  def list_group_invites_by_user(user_id, args \\ []) do
    GroupInviteLib.get_group_invites()
    |> GroupInviteLib.search(user_id: user_id)
    |> GroupInviteLib.search(args[:search])
    |> GroupInviteLib.preload(args[:joins])
    # |> GroupInviteLib.order_by(args[:order_by])
    |> QueryHelpers.select(args[:select])
    |> Repo.all()
  end

  @doc """
  Gets a single group_invite.

  Raises `Ecto.NoResultsError` if the GroupInvite does not exist.

  ## Examples

      iex> get_group_invite!(123)
      %GroupInvite{}

      iex> get_group_invite!(456)
      ** (Ecto.NoResultsError)

  """
  @spec get_group_invite!(T.user_id(), T.group_id()) :: GroupInvite.t()
  def get_group_invite!(user_id, group_id) do
    GroupInviteLib.get_group_invites()
    |> GroupInviteLib.search(%{group_id: group_id, user_id: user_id})
    |> Repo.one!()
  end

  @spec get_group_invite(T.user_id(), T.group_id()) :: GroupInvite.t() | nil
  def get_group_invite(user_id, group_id) do
    GroupInviteLib.get_group_invites()
    |> GroupInviteLib.search(%{group_id: group_id, user_id: user_id})
    |> Repo.one()
  end

  @doc """
  Creates a group_invite.

  ## Examples

      iex> create_group_invite(%{field: value})
      {:ok, %GroupInvite{}}

      iex> create_group_invite(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_group_invite(attrs) do
    %GroupInvite{}
    |> GroupInvite.changeset(attrs)
    |> Repo.insert()
  end

  def create_group_invite(group_id, user_id) do
    %GroupInvite{}
    |> GroupInvite.changeset(%{
      group_id: group_id,
      user_id: user_id
    })
    |> Repo.insert()
  end

  @doc """
  Updates a GroupInvite.

  ## Examples

      iex> update_group_invite(group_invite, %{field: new_value})
      {:ok, %Ruleset{}}

      iex> update_group_invite(group_invite, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_group_invite(%GroupInvite{} = group_invite, attrs) do
    group_invite
    |> GroupInvite.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a GroupInvite.

  ## Examples

      iex> delete_group_invite(group_invite)
      {:ok, %GroupInvite{}}

      iex> delete_group_invite(group_invite)
      {:error, %Ecto.Changeset{}}

  """
  def delete_group_invite(%GroupInvite{} = group_invite) do
    Repo.delete(group_invite)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking group_invite changes.

  ## Examples

      iex> change_group_invite(group_invite)
      %Ecto.Changeset{source: %GroupInvite{}}

  """
  def change_group_invite(%GroupInvite{} = group_invite) do
    GroupInvite.changeset(group_invite, %{})
  end

  @doc """
  Uses :application_metadata_cache store to generate a random username
  based on the keys random_names_1, random_names_2 and random_names_3
  if you override these keys with an empty list you can generate shorter names
  """
  @spec generate_throwaway_name() :: String.t()
  def generate_throwaway_name do
    [
      Central.store_get(:application_metadata_cache, "random_names_1"),
      Central.store_get(:application_metadata_cache, "random_names_2"),
      Central.store_get(:application_metadata_cache, "random_names_3")
    ]
    |> Enum.filter(fn l -> l != [] end)
    |> Enum.map_join(" ", fn l -> Enum.random(l) |> String.capitalize() end)
  end
end
