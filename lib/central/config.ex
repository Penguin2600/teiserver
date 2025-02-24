defmodule Central.Config do
  @moduledoc """
  The Config context.
  """

  import Ecto.Query, warn: false
  alias Central.Repo

  alias Central.Config.UserConfig

  def get_user_config_cache(%{assigns: %{current_user: nil}}, key) do
    get_user_config_default(key)
  end

  def get_user_config_cache(%{assigns: %{current_user: current_user}}, key) do
    get_user_config_cache(current_user.id, key)
  end

  def get_user_config_cache(%{id: id}, key) do
    get_user_config_cache(id, key)
  end

  def get_user_config_cache(user_id, key) do
    value = get_user_configs!(user_id)[key]

    if value do
      cast_user_config_value(key, value)
    else
      get_user_config_default(key)
    end
  end

  def set_user_config(%{assigns: %{current_user: current_user}}, key, value),
    do: set_user_config(current_user.id, key, value)

  def set_user_config(user_id, key, nil) do
    user_configs = get_user_configs!(user_id)

    if user_configs[key] != nil do
      get_user_config!(user_id, key)
      |> delete_user_config
    end
  end

  def set_user_config(user_id, key, value) do
    user_configs = get_user_configs!(user_id)

    if user_configs[key] == nil do
      create_user_config(%{
        "user_id" => user_id,
        "key" => key,
        "value" => value |> to_string
      })
    else
      get_user_config!(user_id, key)
      |> update_user_config(%{
        "value" => value |> to_string
      })
    end
  end

  @doc """
  Gets a single user_config.

  Raises `Ecto.NoResultsError` if the User config does not exist.

  ## Examples

      iex> get_user_config!(123)
      %UserConfig{}

      iex> get_user_config!(456)
      ** (Ecto.NoResultsError)

  """
  def get_user_configs!(nil), do: %{}

  def get_user_configs!(user_id) do
    Central.cache_get_or_store(:config_user_cache, user_id, fn ->
      query =
        from user_config in UserConfig,
          where: user_config.user_id == ^user_id,
          select: {user_config.key, user_config.value}

      Repo.all(query)
      |> Map.new()
    end)
  end

  def get_user_config!(id), do: Repo.get!(UserConfig, id)

  def get_user_config!(user_id, key) do
    query =
      from user_config in UserConfig,
        where: user_config.user_id == ^user_id,
        where: user_config.key == ^key,
        limit: 1

    Repo.one(query)
  end

  # This function exists solely to make deleting user configs easier
  # typically you should be using the get_user_configs! function
  # as it will take advantage of the cache
  def list_user_configs(user_id) do
    query =
      from user_config in UserConfig,
        where: user_config.user_id == ^user_id

    Repo.all(query)
  end

  @doc """
  Creates a user_config.

  ## Examples

      iex> create_user_config(%{field: value})
      {:ok, %UserConfig{}}

      iex> create_user_config(%{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def create_user_config(attrs \\ %{}) do
    Central.cache_delete(:config_user_cache, attrs["user_id"])

    %UserConfig{}
    |> UserConfig.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a user_config.

  ## Examples

      iex> update_user_config(user_config, %{field: new_value})
      {:ok, %UserConfig{}}

      iex> update_user_config(user_config, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_user_config(%UserConfig{} = user_config, attrs) do
    Central.cache_delete(:config_user_cache, user_config.user_id)

    user_config
    |> UserConfig.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a UserConfig.

  ## Examples

      iex> delete_user_config(user_config)
      {:ok, %UserConfig{}}

      iex> delete_user_config(user_config)
      {:error, %Ecto.Changeset{}}

  """
  def delete_user_config(%UserConfig{} = user_config) do
    Central.cache_delete(:config_user_cache, user_config.user_id)
    Repo.delete(user_config)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking user_config changes.

  ## Examples

      iex> change_user_config(user_config)
      %Ecto.Changeset{source: %UserConfig{}}

  """
  def change_user_config(%UserConfig{} = user_config) do
    Central.cache_delete(:config_user_cache, user_config.user_id)
    UserConfig.changeset(user_config, %{})
  end

  # User Config Types
  @spec get_user_config_types :: list()
  def get_user_config_types() do
    Central.store_get(:config_user_type_store, "all-config-types")
  end

  @spec get_user_config_type(String.t()) :: map() | nil
  def get_user_config_type(key) do
    Central.store_get(:config_user_type_store, key)
  end

  @spec get_grouped_user_configs :: map()
  def get_grouped_user_configs() do
    Central.store_get(:config_user_type_store, "all-config-types")
    |> Map.values()
    |> Enum.filter(fn c ->
      c.visible
    end)
    |> Enum.sort(fn c1, c2 ->
      c1.key <= c2.key
    end)
    |> Enum.group_by(fn c ->
      c.section
    end)
  end

  @doc """
  Expects a map with the following fields:

    key: String, dot notation indicating namespace and name of config; spaces allowed
      e.g. account.Favourite colour

    section: String, the tab it would appear under in an options menu. Does not need to be the same as the keyed namespace,
      e.g. "Colours"

    type: String, choose from: string, select, password, boolean, array
      array allows the picking of multiple options

    visible: Boolean, dictates if it is visible in the account settings page

    permissions: Permission list, decides if it can be edited on the account page

    opts: List, used to define options for various data types. If set then only items from the list will be selectable
      - If type is "select" then include a :choices key in your opts list

    default: Any, The default value used when the variable is not set,


    -- Optional params
    description: String, Information presented to the user if they edit it on their settings page. Defaults to an empty string.

    value_label: The label shown next to the value input. Defaults to "Value"
  """

  @spec add_user_config_type(map()) :: :ok
  def add_user_config_type(config) do
    config =
      Map.merge(
        %{
          value_label: "Value",
          description: ""
        },
        config
      )

    all_config_types =
      (Central.store_get(:config_user_type_store, "all-config-types") || %{})
      |> Map.put(config.key, config)

    Central.store_put(:config_user_type_store, "all-config-types", all_config_types)
    Central.store_put(:config_user_type_store, config.key, config)
  end

  @spec get_user_config_default(String.t()) :: any
  def get_user_config_default(key) do
    case get_user_config_type(key) do
      nil -> throw("Invalid config key of #{key}")
      v -> Map.get(v, :default)
    end
  end

  @spec cast_user_config_value(String.t(), any) :: any
  def cast_user_config_value(type_key, value) do
    type = get_user_config_type(type_key)

    case type.type do
      "integer" -> Central.Helpers.NumberHelper.int_parse(value)
      "boolean" -> if value == "true", do: true, else: false
      "select" -> value
      "string" -> value
    end
  end

  alias Central.Config.SiteConfig

  @spec get_site_config_cache(String.t()) :: any
  def get_site_config_cache(key) do
    Central.cache_get_or_store(:config_site_cache, key, fn ->
      case get_site_config(key) do
        nil ->
          default = get_site_config_default(key)
          cast_site_config_value(key, default)

        config ->
          cast_site_config_value(key, config.value)
      end
    end)
  end

  @spec get_site_config(String.t()) :: SiteConfig.t() | nil
  def get_site_config(key) do
    query =
      from site_config in SiteConfig,
        where: site_config.key == ^key

    Repo.one(query)
  end

  @spec update_site_config(String.t(), String.t()) :: :ok
  def update_site_config(key, value) do
    query =
      from site_config in SiteConfig,
        where: site_config.key == ^key,
        limit: 1

    # The key may or may not exist
    {:ok, _config} =
      case Repo.one(query) do
        nil ->
          %SiteConfig{}
          |> SiteConfig.changeset(%{
            key: key,
            value: value
          })
          |> Repo.insert()

        site_config ->
          site_config
          |> SiteConfig.changeset(%{value: value})
          |> Repo.update()
      end

    cached_value = cast_site_config_value(key, value)

    case get_site_config_type(key) do
      nil -> :ok
      %{update_callback: nil} -> :ok
      %{update_callback: callback_func} -> callback_func.(cached_value)
    end

    Central.cache_put(:config_site_cache, key, cached_value)
  end

  @spec delete_site_config(String.t()) :: :ok | {:error, any}
  def delete_site_config(key) do
    query =
      from site_config in SiteConfig,
        where: site_config.key == ^key,
        limit: 1

    # The key may or may not exist
    case Repo.one(query) do
      nil ->
        :ok

      site_config ->
        site_config
        |> Repo.delete()
    end

    Central.cache_delete(:config_site_cache, key)
  end

  # Site Config Types
  @spec get_site_config_types :: list()
  def get_site_config_types() do
    Central.store_get(:config_site_type_store, "all-config-types")
  end

  @spec get_site_config_type(String.t()) :: map | nil
  def get_site_config_type(key) do
    Central.store_get(:config_site_type_store, key)
  end

  @spec get_grouped_site_configs :: map
  def get_grouped_site_configs() do
    (Central.store_get(:config_site_type_store, "all-config-types") || %{})
    |> Map.values()
    |> Enum.sort(fn c1, c2 ->
      c1.key <= c2.key
    end)
    |> Enum.group_by(fn c ->
      c.section
    end)
  end

  @config_defaults %{
    opts: [],
    value_label: "",
    default: nil,
    update_callback: nil,
    tags: []
  }

  @doc """
  Expects a map with the following fields:

    key: String, dot notation indicating namespace and name of config; spaces allowed
      e.g. account.Allow registration

    section: String, the tab it would appear under in an options menu. Does not need to be the same as the keyed namespace,
      e.g. "Registrations"

    type: String, choose from: string, boolean, array
      array allows the picking of multiple options

    permissions: Permission list required to edit this setting

    description: String, Information presented to the user viewing or editing it

    opts: List, used to define options for various data types. If set then only items from the list will be selectable
      - If type is "select" then include a :choices key in your opts list

    default: Any, The default value used when the variable is not set,

    update_callback: A function of arity 1 which will be called on an updated value with the new value
  """
  @spec add_site_config_type(map()) :: :ok
  def add_site_config_type(config) do
    config = Map.merge(@config_defaults, config)

    all_config_types =
      (Central.store_get(:config_site_type_store, "all-config-types") || %{})
      |> Map.put(config.key, config)

    Central.store_put(:config_site_type_store, "all-config-types", all_config_types)
    Central.store_put(:config_site_type_store, config.key, config)
  end

  @spec get_site_config_default(String.t()) :: any
  def get_site_config_default(key) do
    case get_site_config_type(key) do
      nil -> throw("Invalid config key of #{key}")
      v -> Map.get(v, :default)
    end
  end

  @spec cast_site_config_value(String.t(), any) :: any
  def cast_site_config_value(type_key, value) do
    type = get_site_config_type(type_key)

    case type.type do
      "integer" -> Central.Helpers.NumberHelper.int_parse(value)
      "boolean" -> if value == "true" or value == true, do: true, else: false
      "select" -> value
      "string" -> value
    end
  end
end
