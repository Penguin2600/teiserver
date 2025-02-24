defmodule Teiserver.Battle.Lobby do
  # @enforce_keys [:id, :name, :team_size, :icon, :colour, :settings, :conditions, :map_list]
  # defstruct [
  #   id: LobbyIdServer.get_next_id(),

  #   # Expected to be overridden
  #   ip: nil,
  #   port: nil,
  #   engine_version: nil,
  #   map_hash: nil,
  #   map_name: nil,
  #   game_name: nil,
  #   hash_code: nil,

  #   type: "normal",
  #   nattype: :none,
  #   max_players: 16,
  #   password: nil,
  #   rank: 0,
  #   locked: false,
  #   engine_name: "spring",
  #   players: [],

  #   member_count: 0,
  #   player_count: 0,
  #   spectator_count: 0,

  #   disabled_units: [],
  #   start_areas: %{},

  #   # To tie it into matchmaking
  #   queue_id: nil,

  #   # Consul flags
  #   consul_rename: false,

  #   # Meta data
  #   silence: false,
  #   in_progress: false,
  #   started_at: nil
  # ]

  alias Phoenix.PubSub
  require Logger
  import Central.Helpers.NumberHelper, only: [int_parse: 1]
  alias Teiserver.{Account, User, Client, Battle, Coordinator, LobbyIdServer}
  alias Teiserver.Data.Types, as: T
  alias Teiserver.Battle.{LobbyChat, LobbyCache}

  # LobbyChat
  @spec say(Types.userid(), String.t(), Types.lobby_id()) :: :ok | {:error, any}
  def say(userid, msg, lobby_id), do: LobbyChat.say(userid, msg, lobby_id)

  @spec sayex(Types.userid(), String.t(), Types.lobby_id()) :: :ok | {:error, any}
  def sayex(userid, msg, lobby_id), do: LobbyChat.sayex(userid, msg, lobby_id)

  @spec sayprivateex(Types.userid(), Types.userid(), String.t(), Types.lobby_id()) ::
          :ok | {:error, any}
  def sayprivateex(from_id, to_id, msg, lobby_id),
    do: LobbyChat.sayprivateex(from_id, to_id, msg, lobby_id)

  def new_bot(data) do
    Map.merge(
      %{
        player_number: 0,
        team_colour: "0",
        team_number: 0,
        handicap: 0,
        side: 0
      },
      data
    )
  end

  @spec create_lobby(Map.t()) :: T.lobby()
  def create_lobby(%{founder_id: _, founder_name: _, name: _} = lobby) do
    passworded = Map.get(lobby, :password) != nil

    # Needs to be supplied a map with:
    # ip, port, engine_version, map_hash, map_name, game_name, hash_code
    Map.merge(
      %{
        id: LobbyIdServer.get_next_id(),

        # Expected to be overridden
        ip: nil,
        port: nil,
        engine_version: nil,
        map_hash: nil,
        map_name: nil,
        game_name: nil,
        hash_code: nil,
        type: "normal",
        nattype: :none,
        max_players: 16,
        passworded: passworded,
        password: nil,
        rank: 0,
        locked: false,
        engine_name: "spring",
        members: [],
        players: [],

        # When set to false updates to this lobby won't appear in global_battle updates
        public: true,
        member_count: 0,
        player_count: 0,
        spectator_count: 0,
        disabled_units: [],
        start_areas: %{},

        # To tie it into matchmaking
        queue_id: nil,
        match_id: nil,

        # Rename flags
        # consul rename means it was renamed by a player and overrides spads
        consul_rename: false,

        # Used to indicate the lobby is subject to a lobby policy
        lobby_policy_id: nil,

        # Meta data
        tournament: false,
        silence: false,
        in_progress: false,
        started_at: nil
      },
      lobby
    )
  end

  # Cache functions
  @spec list_lobby_ids :: [T.lobby_id()]
  defdelegate list_lobby_ids(), to: LobbyCache

  @spec list_lobbies() :: [T.lobby()]
  defdelegate list_lobbies(), to: LobbyCache

  @spec stream_lobbies() :: Stream.t()
  defdelegate stream_lobbies(), to: LobbyCache

  @spec update_lobby(T.lobby(), nil | atom, any) :: T.lobby()
  defdelegate update_lobby(lobby, data, reason), to: LobbyCache

  @spec get_lobby(T.lobby_id() | nil) :: T.lobby() | nil
  defdelegate get_lobby(id), to: LobbyCache

  defdelegate list_lobby_players!(id), to: LobbyCache
  defdelegate add_lobby(lobby), to: LobbyCache
  defdelegate close_lobby(lobby_id, reason \\ :closed), to: LobbyCache

  @spec start_battle_lobby_throttle(T.lobby_id()) :: pid()
  def start_battle_lobby_throttle(battle_lobby_id) do
    Teiserver.Throttles.start_throttle(
      battle_lobby_id,
      Teiserver.Battle.LobbyThrottle,
      "battle_lobby_throttle_#{battle_lobby_id}"
    )
  end

  @spec stop_battle_lobby_throttle(T.lobby_id()) :: :ok
  def stop_battle_lobby_throttle(battle_lobby_id) do
    # We send this out because the throttle won't
    :ok =
      PubSub.broadcast(
        Central.PubSub,
        "teiserver_liveview_lobby_updates:#{battle_lobby_id}",
        {:battle_lobby_throttle, :closed}
      )

    Teiserver.Throttles.stop_throttle("LobbyThrottle:#{battle_lobby_id}")
    :ok
  end

  @spec force_add_user_to_lobby(T.userid(), T.lobby_id()) :: :ok | nil
  def force_add_user_to_lobby(userid, lobby_id) do
    client = Account.get_client_by_id(userid)

    if client != nil and client.lobby_id != lobby_id and Battle.lobby_exists?(lobby_id) do
      do_force_add_user_to_lobby(client, lobby_id)
    end
  end

  # Used to send the user PID a join battle command
  @spec do_force_add_user_to_lobby(T.client(), T.lobby_id()) :: :ok | nil
  defp do_force_add_user_to_lobby(nil, _), do: nil

  defp do_force_add_user_to_lobby(client, lobby_id) do
    remove_user_from_any_lobby(client.userid)
    script_password = new_script_password()

    add_user_to_battle(client.userid, lobby_id, script_password)

    PubSub.broadcast(
      Central.PubSub,
      "teiserver_client_messages:#{client.userid}",
      %{
        channel: "teiserver_client_messages:#{client.userid}",
        event: :force_join_lobby,
        lobby_id: lobby_id,
        script_password: script_password
      }
    )

    # TODO: Depreciate this
    send(client.tcp_pid, {:force_join_battle, lobby_id, script_password})
    :ok
  end

  @spec add_user_to_battle(integer(), integer()) :: nil
  def add_user_to_battle(userid, lobby_id) do
    add_user_to_battle(userid, lobby_id, new_script_password())
  end

  @spec add_user_to_battle(integer(), integer(), String.t()) :: nil
  def add_user_to_battle(userid, lobby_id, script_password) do
    members = Battle.get_lobby_member_list(lobby_id) || []
    Battle.add_user_to_lobby(userid, lobby_id, script_password)

    if not Enum.member?(members, userid) do
      Coordinator.cast_consul(lobby_id, {:user_joined, userid})
      Client.join_battle(userid, lobby_id, false)
      client = Account.get_client_by_id(userid)

      PubSub.broadcast(
        Central.PubSub,
        "teiserver_global_user_updates",
        %{
          channel: "teiserver_global_user_updates",
          event: :joined_lobby,
          lobby_id: lobby_id,
          client: client,
          script_password: script_password
        }
      )

      PubSub.broadcast(
        Central.PubSub,
        "teiserver_client_messages:#{userid}",
        %{
          channel: "teiserver_client_messages:#{userid}",
          event: :added_to_lobby,
          lobby_id: lobby_id,
          script_password: script_password
        }
      )

      PubSub.broadcast(
        Central.PubSub,
        "teiserver_client_watch:#{userid}",
        %{
          channel: "teiserver_client_watch:#{userid}",
          event: :added_to_lobby,
          lobby_id: lobby_id
        }
      )

      PubSub.broadcast(
        Central.PubSub,
        "teiserver_lobby_updates:#{lobby_id}",
        %{
          channel: "teiserver_lobby_updates",
          event: :add_user,
          lobby_id: lobby_id,
          client: client,
          script_password: script_password
        }
      )
    end
  end

  @spec remove_user_from_battle(T.userid(), T.lobby_id()) :: nil | :ok | {:error, any}
  def remove_user_from_battle(_uid, nil), do: nil

  def remove_user_from_battle(userid, lobby_id) do
    Client.leave_battle(userid)

    case do_remove_user_from_lobby(userid, lobby_id) do
      :closed ->
        nil

      :not_member ->
        nil

      :no_battle ->
        nil

      :removed ->
        Coordinator.cast_consul(lobby_id, {:user_left, userid})
        client = Account.get_client_by_id(userid)

        PubSub.broadcast(
          Central.PubSub,
          "teiserver_global_user_updates",
          %{
            channel: "teiserver_global_user_updates",
            event: :left_lobby,
            lobby_id: lobby_id,
            client: client
          }
        )

        PubSub.broadcast(
          Central.PubSub,
          "teiserver_client_watch:#{userid}",
          %{
            channel: "teiserver_client_watch:#{userid}",
            event: :left_lobby,
            lobby_id: lobby_id
          }
        )

        PubSub.broadcast(
          Central.PubSub,
          "teiserver_lobby_updates:#{lobby_id}",
          %{
            channel: "teiserver_lobby_updates",
            event: :remove_user,
            lobby_id: lobby_id,
            client: client
          }
        )
    end
  end

  @spec kick_user_from_battle(T.userid(), T.lobby_id()) :: nil | :ok | {:error, any}
  def kick_user_from_battle(userid, lobby_id) do
    user = User.get_user_by_id(userid)

    if User.is_moderator?(user) do
      :ok
    else
      case do_remove_user_from_lobby(userid, lobby_id) do
        :closed ->
          :ok

        :not_member ->
          :ok

        :no_battle ->
          :ok

        :removed ->
          Coordinator.cast_consul(lobby_id, {:user_kicked, userid})
          client = Account.get_client_by_id(userid)

          PubSub.broadcast(
            Central.PubSub,
            "teiserver_global_user_updates",
            %{
              channel: "teiserver_global_user_updates",
              event: :kicked_from_lobby,
              lobby_id: lobby_id,
              client: client
            }
          )

          PubSub.broadcast(
            Central.PubSub,
            "teiserver_client_watch:#{userid}",
            %{
              channel: "teiserver_client_watch:#{userid}",
              event: :left_lobby,
              lobby_id: lobby_id
            }
          )

          PubSub.broadcast(
            Central.PubSub,
            "teiserver_lobby_updates:#{lobby_id}",
            %{
              channel: "teiserver_lobby_updates",
              event: :kick_user,
              lobby_id: lobby_id,
              client: client
            }
          )
      end
    end
  end

  @spec remove_user_from_any_lobby(integer() | nil) :: list()
  def remove_user_from_any_lobby(nil), do: []

  def remove_user_from_any_lobby(userid) do
    lobby_ids =
      Battle.list_lobby_ids()
      |> Enum.map(fn lobby_id ->
        Battle.get_lobby(lobby_id)
      end)
      |> Enum.filter(fn lobby ->
        lobby != nil and (Enum.member?(lobby.members, userid) or lobby.founder_id == userid)
      end)
      |> Enum.map(fn lobby ->
        remove_user_from_battle(userid, lobby.id)
        lobby.id
      end)

    if Enum.count(lobby_ids) > 1 do
      Logger.error("#{userid} is a member of #{Enum.count(lobby_ids)} battles")
    end

    lobby_ids
  end

  @spec find_empty_lobby(function()) :: Map.t()
  def find_empty_lobby(filter_func \\ fn _ -> true end) do
    empties =
      stream_lobbies()
      |> Stream.filter(fn lobby -> lobby.in_progress == false and Enum.empty?(lobby.players) end)
      |> Stream.filter(filter_func)
      |> Stream.take(1)
      |> Enum.to_list()

    case empties do
      [] -> nil
      [l] -> l
    end
  end

  @spec do_remove_user_from_lobby(integer(), integer()) ::
          :closed | :removed | :not_member | :no_battle
  defp do_remove_user_from_lobby(userid, lobby_id) do
    battle = get_lobby(lobby_id)
    Client.leave_battle(userid)
    Battle.remove_user_from_lobby(userid, lobby_id)

    if battle do
      if battle.founder_id == userid do
        close_lobby(lobby_id)
        :closed
      else
        if Enum.member?(battle.members, userid) do
          bots = Battle.get_bots(lobby_id) || []

          # Remove all their bots
          bots
          |> Enum.each(fn {botname, bot} ->
            if bot.owner_id == userid do
              Battle.remove_bot(lobby_id, botname)
            end
          end)

          :removed
        else
          :not_member
        end
      end
    else
      :no_battle
    end
  end

  @spec rename_lobby(T.lobby_id(), String.t()) :: :ok
  @spec rename_lobby(T.lobby_id(), String.t(), boolean) :: :ok
  def rename_lobby(lobby_id, new_name, consul_rename \\ false) do
    case Battle.lobby_exists?(lobby_id) do
      false ->
        nil

      true ->
        Battle.update_lobby_values(lobby_id, %{
          name: new_name,
          consul_rename: consul_rename
        })
    end

    :ok
  end

  # Start rects
  def add_start_rectangle(lobby_id, [team, a, b, c, d]) do
    [team, a, b, c, d] = int_parse([team, a, b, c, d])
    LobbyCache.add_start_rectangle(lobby_id, team, [a, b, c, d])
  end

  def remove_start_rectangle(lobby_id, team_id) do
    LobbyCache.remove_start_area(lobby_id, team_id)
  end

  @spec lock_lobby(T.lobby_id()) :: :ok | nil
  def lock_lobby(lobby_id) when is_integer(lobby_id) do
    Battle.update_lobby_values(lobby_id, %{locked: true})
  end

  @spec unlock_lobby(T.lobby_id()) :: :ok | nil
  def unlock_lobby(lobby_id) when is_integer(lobby_id) do
    Battle.update_lobby_values(lobby_id, %{locked: true})
  end

  @spec silence_lobby(T.lobby() | T.lobby_id()) :: :ok
  def silence_lobby(lobby_id) when is_integer(lobby_id) do
    Battle.update_lobby_values(lobby_id, %{silence: true})
  end

  def silence_lobby(%{id: lobby_id}) do
    Battle.update_lobby_values(lobby_id, %{silence: true})
  end

  @spec unsilence_lobby(T.lobby() | T.lobby_id()) :: T.lobby()
  def unsilence_lobby(lobby_id) when is_integer(lobby_id),
    do: unsilence_lobby(get_lobby(lobby_id))

  def unsilence_lobby(lobby) do
    update_lobby(%{lobby | silence: false}, nil, :unsilence)
  end

  @spec can_join?(Types.userid(), integer(), String.t() | nil, String.t() | nil) ::
          {:failure, String.t()} | {:waiting_on_host, String.t()}
  def can_join?(userid, lobby_id, password \\ nil, script_password \\ nil) do
    lobby_id = int_parse(lobby_id)
    server_result = server_allows_join?(userid, lobby_id, password)

    if server_result == true do
      script_password =
        if script_password == nil, do: new_script_password(), else: script_password

      lobby = get_lobby(lobby_id)

      if lobby != nil do
        case Account.get_client_by_id(lobby.founder_id) do
          nil ->
            {:failure, "Battle closed"}

          host_client ->
            # TODO: Depreciate
            send(host_client.tcp_pid, {:request_user_join_lobby, userid})

            PubSub.broadcast(
              Central.PubSub,
              "teiserver_lobby_host_message:#{lobby_id}",
              %{
                channel: "teiserver_lobby_host_message:#{lobby_id}",
                event: :user_requests_to_join,
                lobby_id: lobby_id,
                userid: userid,
                script_password: script_password
              }
            )

            {:waiting_on_host, script_password}
        end
      else
        {:failure, "No lobby found (type 2)"}
      end
    else
      server_result
    end
  end

  @spec server_allows_join?(Types.userid(), integer(), String.t() | nil) ::
          {:failure, String.t()} | true
  def server_allows_join?(userid, lobby_id, password \\ nil) do
    lobby = get_lobby(lobby_id)
    user = Account.get_user_by_id(userid)

    # In theory this would never happen but it's possible to see this at startup when
    # not everything is loaded and ready, hence the case statement
    {consul_response, consul_reason} =
      case Coordinator.call_consul(lobby_id, {:request_user_join_lobby, userid}) do
        {a, b} ->
          {a, b}

        nil ->
          {true, nil}

        v ->
          Logger.error("ConsulServer can_join? error, response #{Kernel.inspect(v)}")
          {false, "ConsulServer error on can_join? call"}
      end

    ignore_password =
      Enum.any?([
        User.is_moderator?(user),
        Enum.member?(user.roles, "Caster"),
        consul_reason == :override_approve
      ])

    ignore_locked =
      Enum.any?([
        User.is_moderator?(user),
        Enum.member?(user.roles, "Caster"),
        consul_reason == :override_approve
      ])

    cond do
      user == nil ->
        {:failure, "You are not a user"}

      lobby == nil ->
        {:failure, "No lobby found (type 1)"}

      lobby.locked == true and ignore_locked == false ->
        {:failure, "Battle locked"}

      lobby.password != nil and password != lobby.password and not ignore_password ->
        {:failure, "Invalid password"}

      consul_response == false ->
        {:failure, consul_reason}

      User.is_restricted?(user, ["All lobbies", "Joining existing lobbies"]) ->
        {:failure, "You are currently banned from joining lobbies"}

      true ->
        true
    end
  end

  @spec accept_join_request(T.userid(), T.lobby_id()) :: :ok
  def accept_join_request(userid, lobby_id) do
    client = Client.get_client_by_id(userid)

    if client do
      # TODO: Depreciate
      send(client.tcp_pid, {:join_battle_request_response, lobby_id, :accept, nil})
    end

    PubSub.broadcast(
      Central.PubSub,
      "teiserver_client_messages:#{userid}",
      %{
        channel: "teiserver_client_messages:#{userid}",
        event: :join_lobby_request_response,
        lobby_id: lobby_id,
        response: :accept
      }
    )

    # TODO: Refactor this as per the TODO list, this should take place here and not in the client process
    # add_user_to_battle(userid, lobby_id)

    :ok
  end

  @spec deny_join_request(T.userid(), T.lobby_id(), String.t()) :: :ok
  def deny_join_request(userid, lobby_id, reason) do
    PubSub.broadcast(
      Central.PubSub,
      "teiserver_client_messages:#{userid}",
      %{
        channel: "teiserver_client_messages:#{userid}",
        event: :join_lobby_request_response,
        lobby_id: lobby_id,
        response: :deny,
        reason: reason
      }
    )

    client = Client.get_client_by_id(userid)

    if client do
      # TODO: Depreciate
      send(client.tcp_pid, {:join_battle_request_response, lobby_id, :deny, reason})
    end

    :ok
  end

  @spec force_change_client(T.userid(), T.userid(), Map.t()) :: :ok
  def force_change_client(_, nil, _), do: nil

  def force_change_client(changer_id, client_id, new_values) do
    case Client.get_client_by_id(client_id) do
      nil ->
        nil

      client ->
        lobby = get_lobby(client.lobby_id)
        changer = Client.get_client_by_id(changer_id)

        changed_values =
          new_values
          |> Enum.filter(fn {field, _} ->
            allow?(changer, field, lobby)
          end)
          |> Map.new(fn {k, v} -> {k, v} end)

        change_client_battle_status(client, changed_values)
    end
  end

  @spec change_client_battle_status(Map.t(), Map.t()) :: Map.t()
  def change_client_battle_status(nil, _), do: nil
  def change_client_battle_status(_, values) when values == %{}, do: nil

  def change_client_battle_status(client, new_values) do
    new_client = Map.merge(client, new_values)
    Account.replace_update_client(new_client, :client_updated_battlestatus)
  end

  @spec allow?(T.userid(), atom, T.lobby_id()) :: boolean()
  def allow?(nil, _, _), do: false
  def allow?(_, nil, _), do: false
  def allow?(_, _, nil), do: false

  def allow?(userid, :saybattle, lobby_id), do: allow_say?(userid, lobby_id)
  def allow?(userid, :saybattleex, lobby_id), do: allow_say?(userid, lobby_id)

  def allow?(_userid, :host, _), do: true

  def allow?(changer, field, lobby_id) when is_integer(lobby_id),
    do: allow?(changer, field, get_lobby(lobby_id))

  def allow?(changer_id, field, battle) when is_integer(changer_id),
    do: allow?(Client.get_client_by_id(changer_id), field, battle)

  def allow?(changer, {:remove_bot, botname}, lobby),
    do: allow?(changer, {:bot_command, botname}, lobby)

  def allow?(changer, {:update_bot, botname}, lobby),
    do: allow?(changer, {:bot_command, botname}, lobby)

  def allow?(changer, {:bot_command, botname}, lobby) do
    bots = Battle.get_bots(lobby.id)
    bot = bots[botname]

    cond do
      bot == nil ->
        false

      User.is_moderator?(changer) == true ->
        true

      lobby.founder_id == changer.userid ->
        true

      bot.owner_id == changer.userid ->
        true

      true ->
        false
    end
  end

  def allow?(changer, cmd, battle) do
    mod_command =
      Enum.member?(
        [
          :handicap,
          :updatebattleinfo,
          :addstartrect,
          :removestartrect,
          :kickfrombattle,
          :player_number,
          :team_number,
          :player,
          :disableunits,
          :enableunits,
          :enableallunits,
          :update_lobby,
          :update_lobby_title,
          :update_host_status
        ],
        cmd
      )

    player_command =
      Enum.member?(
        [
          :add_bot
        ],
        cmd
      )

    cond do
      User.is_moderator?(changer) == true ->
        true

      # If the battle has been renamed by the consul then we'll keep it renamed as such
      battle.consul_rename == true and cmd == :update_lobby_title ->
        false

      # Basic stuff
      battle.founder_id == changer.userid ->
        true

      # If they're not a moderator/founder then they can't
      # do founder commands
      mod_command == true ->
        false

      player_command == true and changer.player == false ->
        false

      # If they're not a member they can't do anything either
      not Enum.member?(battle.players, changer.userid) ->
        false

      # Default to true
      true ->
        true
    end
  end

  @spec allow_say?(T.userid(), T.lobby_id()) :: boolean()
  def allow_say?(userid, lobby_id) do
    lobby = get_lobby(lobby_id)

    cond do
      lobby == nil ->
        false

      User.is_shadowbanned?(userid) ->
        false

      User.is_restricted?(userid, ["All chat", "Lobby chat"]) ->
        false

      lobby.founder_id == userid ->
        true

      User.is_moderator?(userid) ->
        true

      lobby.silence ->
        false

      true ->
        true
    end
  end

  @spec new_script_password() :: String.t()
  def new_script_password() do
    ExULID.ULID.generate()
    |> Base.encode32(padding: false)
  end
end
