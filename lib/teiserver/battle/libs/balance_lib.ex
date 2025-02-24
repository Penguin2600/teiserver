defmodule Teiserver.Battle.BalanceLib do
  @moduledoc """
  A set of functions related to balance, if you are looking to see how balance is implemented this is the place. Ratings are calculated via Teiserver.Game.MatchRatingLib and are used here. Please note ratings and balance are two very different things and complaints about imbalanced games need to be correct in addressing balance vs ratings.

  Currently the algorithm is "Loser picks". The Algorithm at a high level is:
  1: Dealing with parties
    - Go through all groups of 2 or more members and combine their ratings to create one rating for the group
    - If the group can be paired against a group of equal strength or if any of the remaining solo players can be combined to form a group of sufficiently equal strength, the original group remains intact
    - Any groups that cannot be matched against a suitable group will be broken into solo players and balanced as such

  2: Placing paired groups
    - Each pairing of groups are iterated through and assigned to opposite teams
    - The team with the lowest combined rating picks first and selects the highest rated group

  3: Solo players
    - As long as there are players left to place
    - Whichever team with the lowest combined rating and is not full picks next
    - Said team always picks the highest rated group available
  """
  alias Central.Config
  alias Teiserver.Data.Types, as: T
  alias Teiserver.Account
  alias Teiserver.Game.MatchRatingLib
  import Central.Helpers.NumberHelper, only: [int_parse: 1, round: 2]

  # These are default values and can be overridden as part of the call to create_balance()

  # Upper boundary is how far above the group value the members can be, lower is how far below it
  # these values are in general used for group pairing where we look at making temporary groups on
  # each team to make the battle fair
  @rating_lower_boundary 3
  @rating_upper_boundary 5

  @mean_diff_max 5
  @stddev_diff_max 3

  # Fuzz multiplier is used by the BalanceServer to prevent two games being completely identical
  # teams. It is defaulted here as the server uses this library to get defaults
  @fuzz_multiplier 0.5

  # When set to true, if there are any teams with 0 points (first pick) it randomises
  # which one will get to pick first
  @shuffle_first_pick true

  @spec defaults() :: map()
  def defaults() do
    %{
      max_deviation: Config.get_site_config_cache("teiserver.Max deviation"),
      rating_lower_boundary: @rating_lower_boundary,
      rating_upper_boundary: @rating_upper_boundary,
      mean_diff_max: @mean_diff_max,
      stddev_diff_max: @stddev_diff_max,
      fuzz_multiplier: @fuzz_multiplier,
      shuffle_first_pick: @shuffle_first_pick
    }
  end

  @type rating_value() :: float()
  @type player_group() :: %{T.userid() => rating_value()}
  @type expanded_group() :: %{
          members: [T.userid()],
          ratings: [rating_value()],
          group_rating: rating_value(),
          count: non_neg_integer()
        }
  @type expanded_group_or_pair() :: expanded_group() | {expanded_group(), expanded_group()}

  @doc """
  groups is a list of maps of %{userid => rating_value}

  The result format with the following keys:
  captains: map of team_id => user_id of highest ranked player in the team
  deviation: non_neg_integer()
  ratings: map of team_id => combined rating_value for team
  team_players: map of team_id => list of userids of players on that team
  team_sizes: map of team_id => non_neg_integer
  team_groups: map of team_id => list of expanded_groups

  Options are:
    mode

    rating_lower_boundary: the amount of rating points to search below a party
    rating_upper_boundary: the amount of rating points to search above a party

    mean_diff_max: the maximum difference in mean between the party and paired parties
    stddev_diff_max: the maximum difference in stddev between the party and paired parties
  """
  @spec create_balance([player_group()], non_neg_integer()) :: map()
  @spec create_balance([player_group()], non_neg_integer(), List.t()) :: map()
  def create_balance(groups, team_count, opts \\ []) do
    start_time = System.system_time(:microsecond)

    # We perform all our group calculations here and assign each group
    # an ID that's used purely for this run of balance
    expanded_groups =
      groups
      |> Enum.map(fn members ->
        userids = Map.keys(members)
        ratings = Map.values(members)

        %{
          members: userids,
          ratings: ratings,
          group_rating: Enum.sum(ratings),
          count: Enum.count(ratings)
        }
      end)

    # Now we have a list of groups, we need to work out which groups we're going to keep
    # we want to create partner groups but we're only going to do this in a 2 team game
    # because in a team ffa it'll be very problematic
    solo_players =
      expanded_groups
      |> Enum.filter(fn %{count: count} -> count == 1 end)

    groups =
      expanded_groups
      |> Enum.filter(fn %{count: count} -> count > 1 end)

    {group_pairs, solo_players, group_logs} =
      matchup_groups(groups, solo_players, opts ++ [team_count: team_count])

    # We now need to sort the solo players by rating
    solo_players =
      solo_players
      |> Enum.sort_by(fn %{group_rating: rating} -> rating end, &>=/2)

    teams =
      Range.new(1, team_count || 1)
      |> Map.new(fn i ->
        {i, []}
      end)

    {reversed_team_groups, logs} =
      case opts[:algorithm] || :loser_picks do
        :loser_picks ->
          loser_picks(group_pairs ++ solo_players, teams, opts)

        :force_party ->
          force_party(group_pairs ++ solo_players, teams, opts)
      end

    team_groups =
      reversed_team_groups
      |> Map.new(fn {team_id, groups} ->
        {team_id, Enum.reverse(groups)}
      end)

    team_players =
      team_groups
      |> Map.new(fn {team, groups} ->
        players =
          groups
          |> Enum.map(fn %{members: members} -> members end)
          |> List.flatten()

        {team, players}
      end)

    time_taken = System.system_time(:microsecond) - start_time

    %{
      team_groups: team_groups,
      team_players: team_players,
      logs: group_logs ++ logs,
      time_taken: time_taken
    }
    |> calculate_balance_stats
  end

  # We return a list of groups, a list of solo players and logs generated in the process
  # the purpose of this function is to go through the groups, work out which ones we can keep as
  # groups and with the ones we can't, break them up and add them back into the pool of solo
  # players for other groups
  @spec matchup_groups([expanded_group()], [expanded_group()], list()) ::
          {[expanded_group()], [expanded_group()], [String.t()]}
  defp matchup_groups([], solo_players, _opts), do: {[], solo_players, []}

  defp matchup_groups(groups, solo_players, opts) do
    # First we want to re-sort these groups, we want to have the ones with the highest standard
    # deviation looked at first, they are the least likely to be able to be matched but most likely to
    # help match others
    groups =
      groups
      |> Enum.sort_by(
        fn group ->
          {group.count, Statistics.stdev(group.ratings)}
        end,
        &<=/2
      )

    do_matchup_groups(groups ++ solo_players, [], [], opts)
  end

  # First argument is a list of groups (size 1 included) that need to be paired
  # the second argument is a list of the logs built up by the function
  # thirdly is a list of already paired up groups (so can't be paired up further)
  # fourth is the opts list
  # the function returns a tuple of
  # 1: paired groups
  # 2: non-paired groups
  # 3: logs
  @spec do_matchup_groups([expanded_group()], [String.t()], [expanded_group()], list()) ::
          {[expanded_group()], [expanded_group()], [String.t()]}
  # No groups, no logs
  defp do_matchup_groups([], [], previous_paired_groups, _opts) do
    {previous_paired_groups, [], []}
  end

  # No remaining groups but have some logs
  defp do_matchup_groups([], logs, previous_paired_groups, _opts) do
    {previous_paired_groups, [], logs ++ ["End of pairing"]}
  end

  # This matches when the next group is a size 1, we no longer need to pair up
  defp do_matchup_groups(
         [%{count: 1} | _] = remaining_players,
         logs,
         previous_paired_groups,
         _opts
       ) do
    {previous_paired_groups, remaining_players, logs ++ ["End of pairing"]}
  end

  # Main function clause
  defp do_matchup_groups([group | remaining_groups], logs, previous_paired_groups, opts) do
    group_mean = Enum.sum(group.ratings) / Enum.count(group.ratings)
    group_stddev = Statistics.stdev(group.ratings)

    {_remaining_solo, found_groups} =
      1..(opts[:team_count] - 1)
      |> Enum.reduce({remaining_groups, []}, fn _, {groups_to_search, results} ->
        result = find_comparable_group(group, groups_to_search, opts)

        new_groups_to_search =
          case result do
            :no_possible_combinations ->
              []

            :no_possible_players ->
              []

            %{members: found_members} ->
              groups_to_search
              |> Enum.reject(fn %{members: members} ->
                members
                |> Enum.any?(fn userid -> Enum.member?(found_members, userid) end)
              end)
          end

        {new_groups_to_search, [result | results]}
      end)

    case hd(found_groups) do
      :no_possible_combinations ->
        extra_solos =
          Enum.zip(group.members, group.ratings)
          |> Enum.map(fn {userid, rating} ->
            %{
              count: 1,
              group_rating: rating,
              members: [userid],
              ratings: [rating]
            }
          end)

        names =
          group.members
          |> Enum.map_join(", ", fn userid -> Account.get_username_by_id(userid) || userid end)

        pairing_logs = [
          "Unable to find a combination match for group of #{names} (stats: #{Enum.sum(group.ratings) |> round(2)}, #{group_mean |> round(2)}, #{group_stddev |> round(2)}), treating them as solo players"
        ]

        do_matchup_groups(
          remaining_groups ++ extra_solos,
          logs ++ pairing_logs,
          previous_paired_groups,
          opts
        )

      :no_possible_players ->
        extra_solos =
          Enum.zip(group.members, group.ratings)
          |> Enum.map(fn {userid, rating} ->
            %{
              count: 1,
              group_rating: rating,
              members: [userid],
              ratings: [rating]
            }
          end)

        names =
          group.members
          |> Enum.map_join(", ", fn userid -> Account.get_username_by_id(userid) || userid end)

        pairing_logs = [
          "Unable to find a player match for group of #{names} (stats: #{Enum.sum(group.ratings) |> round(2)}, #{group_mean |> round(2)}, #{group_stddev |> round(2)}), treating them as solo players"
        ]

        do_matchup_groups(
          remaining_groups ++ extra_solos,
          logs ++ pairing_logs,
          previous_paired_groups,
          opts
        )

      _ ->
        # Calculate remaining solo players
        combined_member_ids =
          found_groups
          |> Enum.map(fn g -> g.members end)
          |> List.flatten()

        remaining_groups =
          remaining_groups
          |> Enum.reject(fn %{members: members} ->
            members
            |> Enum.any?(fn userid -> Enum.member?(combined_member_ids, userid) end)
          end)

        # Generate log lines, using fgroup so it doesn't clash with group used
        # earlier
        grouped_logs =
          [group | found_groups]
          |> Enum.map(fn fgroup ->
            fgroup_name =
              fgroup.members
              |> Enum.map_join(", ", fn userid -> Account.get_username_by_id(userid) || userid end)

            fgroup_mean = Enum.sum(fgroup.ratings) / Enum.count(fgroup.ratings)
            fgroup_stddev = Statistics.stdev(fgroup.ratings)

            [
              "> Grouped: #{fgroup_name}",
              "--- Rating sum: #{fgroup.group_rating |> round(2)}",
              "--- Rating Mean: #{fgroup_mean |> round(2)}",
              "--- Rating Stddev: #{fgroup_stddev |> round(2)}"
            ]
          end)
          |> List.flatten()

        logs = ["Group matching" | logs]

        # Now order the groups by rating so we can pick in the right order
        found_groups =
          [group | found_groups]
          |> Enum.sort_by(fn fg -> fg.group_rating end, &>=/2)

        do_matchup_groups(
          remaining_groups,
          logs ++ grouped_logs,
          [found_groups | previous_paired_groups],
          opts
        )
    end
  end

  @doc """
  Given a map from create_balance it will add in some stats
  """
  @spec calculate_balance_stats(map()) :: map()
  def calculate_balance_stats(data) do
    ratings =
      data.team_groups
      |> Map.new(fn {k, groups} ->
        {k, sum_group_rating(groups)}
      end)

    # The first group in the list will be the highest ranked
    # we take the captain as the first member of that group
    captains =
      data.team_groups
      |> Map.new(fn {k, groups} ->
        case groups do
          [] ->
            {k, nil}

          _ ->
            captain =
              groups
              |> hd
              |> Map.get(:members)
              |> hd

            {k, captain}
        end
      end)

    team_sizes =
      data.team_players
      |> Map.new(fn {team, members} -> {team, Enum.count(members)} end)

    means =
      ratings
      |> Map.new(fn {team, rating_sum} ->
        {team, rating_sum / max(team_sizes[team], 1)}
      end)

    stdevs =
      data.team_groups
      |> Map.new(fn {team, group} ->
        stdev =
          group
          |> Enum.map(fn m -> m.ratings end)
          |> List.flatten()
          |> Statistics.stdev()

        {team, stdev}
      end)

    Map.merge(data, %{
      stdevs: stdevs,
      means: means,
      team_sizes: team_sizes,
      ratings: ratings,
      captains: captains,
      deviation: get_deviation(ratings)
    })
  end

  @spec default_rating :: List.t()
  @spec default_rating(non_neg_integer()) :: List.t()
  def default_rating(rating_type_id \\ nil) do
    {skill, uncertainty} = Openskill.rating()
    rating_value = calculate_rating_value(skill, uncertainty)
    leaderboard_rating = calculate_leaderboard_rating(skill, uncertainty)

    %{
      rating_type_id: rating_type_id,
      skill: skill,
      uncertainty: uncertainty,
      rating_value: rating_value,
      leaderboard_rating: leaderboard_rating
    }
  end

  @spec get_user_rating_value_uncertainty_pair(T.userid(), String.t() | non_neg_integer()) ::
          {rating_value(), number()}
  def get_user_rating_value_uncertainty_pair(userid, rating_type_id)
      when is_integer(rating_type_id) do
    rating = Account.get_rating(userid, rating_type_id) || default_rating()

    {
      rating.rating_value,
      rating.uncertainty
    }
  end

  def get_user_rating_value_uncertainty_pair(userid, rating_type) do
    rating_type_id = MatchRatingLib.rating_type_name_lookup()[rating_type]
    get_user_rating_value_uncertainty_pair(userid, rating_type_id)
  end

  @doc """
  Used to get the rating value of the user for public/reporting purposes
  """
  @spec get_user_rating_value(T.userid(), String.t() | non_neg_integer()) :: rating_value()
  def get_user_rating_value(userid, rating_type_id) when is_integer(rating_type_id) do
    Account.get_rating(userid, rating_type_id) |> convert_rating()
  end

  def get_user_rating_value(_userid, nil), do: nil

  def get_user_rating_value(userid, rating_type) do
    rating_type_id = MatchRatingLib.rating_type_name_lookup()[rating_type]
    get_user_rating_value(userid, rating_type_id)
  end

  @doc """
  Used to get the rating value of the user for internal balance purposes which might be
  different from public/reporting
  """
  @spec get_user_balance_rating_value(T.userid(), String.t() | non_neg_integer()) ::
          rating_value()
  def get_user_balance_rating_value(userid, rating_type_id) when is_integer(rating_type_id) do
    real_rating = get_user_rating_value(userid, rating_type_id)

    stats = Account.get_user_stat_data(userid)
    adjustment = int_parse(stats["os_global_adjust"])

    real_rating + adjustment
  end

  def get_user_balance_rating_value(_userid, nil), do: nil

  def get_user_balance_rating_value(userid, rating_type) do
    rating_type_id = MatchRatingLib.rating_type_name_lookup()[rating_type]
    get_user_balance_rating_value(userid, rating_type_id)
  end

  @doc """
  Given a Rating object or nil, return a value representing the rating to be used
  """
  @spec convert_rating(map() | nil) :: rating_value()
  def convert_rating(nil) do
    default_rating() |> convert_rating()
  end

  def convert_rating(%{rating_value: rating_value}) do
    rating_value
  end

  @spec calculate_rating_value(float(), float()) :: float()
  def calculate_rating_value(skill, uncertainty) do
    max(skill - uncertainty, 0)
  end

  @doc """
  Each round the team with the lowest score picks, if a team has the maximum number of players
  they are not allowed to continue picking.

  groups is a list of tuples: {members, rating, member_count}
  """
  @spec loser_picks([expanded_group_or_pair()], map(), list()) :: {map(), list()}
  def loser_picks(groups, teams, opts) do
    total_members =
      groups
      |> Enum.map(fn
        {%{count: count1}, %{count: count2}} ->
          count1 + count2

        %{count: count} ->
          count

        group_list ->
          group_list
          |> Enum.map(fn g -> g.count end)
          |> Enum.sum()
      end)
      |> Enum.sum()

    max_teamsize = (total_members / Enum.count(teams)) |> :math.ceil() |> round()
    do_loser_picks(groups, teams, max_teamsize, [], opts)
  end

  @spec do_loser_picks([expanded_group()], map(), non_neg_integer(), list(), list()) ::
          {map(), list()}
  defp do_loser_picks([], teams, _, logs, _opts), do: {teams, logs}

  defp do_loser_picks([picked | remaining_groups], teams, max_teamsize, logs, opts) do
    team_skills =
      teams
      |> Enum.reject(fn {_team_number, member_groups} ->
        size = sum_group_membership_size(member_groups)
        size >= max_teamsize
      end)
      |> Enum.map(fn {team_number, member_groups} ->
        score = sum_group_rating(member_groups)

        {score, team_number}
      end)
      |> Enum.sort()

    case picked do
      # Single player
      %{count: 1} ->
        current_team =
          if opts[:shuffle_first_pick] do
            # Filter out any team with a higher rating than the first
            low_rating = hd(team_skills) |> elem(0)

            team_skills
            |> Enum.reject(fn {rating, _id} -> rating > low_rating end)
            |> Enum.shuffle()
            |> hd
            |> elem(1)
          else
            hd(team_skills)
            |> elem(1)
          end

        new_team = [picked | teams[current_team]]
        new_team_map = Map.put(teams, current_team, new_team)

        names =
          picked.members
          |> Enum.map_join(", ", fn userid -> Account.get_username_by_id(userid) || userid end)

        new_total = (hd(team_skills) |> elem(0)) + picked.group_rating

        new_logs =
          logs ++
            [
              "Picked #{names} for team #{current_team}, adding #{round(picked.group_rating, 2)} points for new total of #{round(new_total, 2)}"
            ]

        do_loser_picks(remaining_groups, new_team_map, max_teamsize, new_logs, opts)

      # Groups, so we just merge a bunch of them into teams
      groups ->
        # Generate new team map
        new_team_map =
          team_skills
          |> Enum.zip(groups)
          |> Map.new(fn {{_points, team_number}, group} ->
            team = teams[team_number] || []
            {team_number, [group | team]}
          end)

        # Generate logs
        extra_logs =
          team_skills
          |> Enum.zip(groups)
          |> Enum.map(fn {{points, team_number}, group} ->
            names =
              group.members
              |> Enum.map_join(", ", fn userid -> Account.get_username_by_id(userid) || userid end)

            new_team_total = points + group.group_rating

            "Group picked #{names} for team #{team_number}, adding #{round(group.group_rating, 2)} points for new total of #{round(new_team_total, 2)}"
          end)

        new_logs = logs ++ extra_logs

        do_loser_picks(remaining_groups, new_team_map, max_teamsize, new_logs, opts)
    end
  end

  @doc """
  Very similar to loser picks but parties are expected to be paired up.
  """
  @spec force_party([expanded_group_or_pair()], map(), list()) :: {map(), list()}
  def force_party(groups, teams, opts) do
    IO.puts("")
    IO.inspect({groups, teams, opts})
    IO.puts("")

    # To prevent anything breaking while we debug this, return loser picks stuff
    loser_picks(groups, teams, opts)
  end

  @doc """
  Expects a map of %{team_id => rating_value}

  Returns the deviation in percentage points between the two teams
  """
  @spec get_deviation(map()) :: non_neg_integer()
  def get_deviation(team_ratings) do
    scores =
      team_ratings
      |> Enum.sort_by(fn {_team, rating} -> rating end, &>=/2)

    case scores do
      [] ->
        0

      [_] ->
        0

      _ ->
        raw_scores =
          scores
          |> Enum.map(fn {_, s} -> s end)

        [max_score | remaining] = raw_scores
        [min_score | _] = remaining

        # Max score skill needs always be at least one for this to not bork
        max_score = max(max_score, 1)

        ((1 - min_score / max_score) * 100)
        |> round
        |> abs
    end
  end

  # Given a list of groups, return the combined number of members
  @spec sum_group_membership_size([expanded_group()]) :: non_neg_integer()
  defp sum_group_membership_size([]), do: 0

  defp sum_group_membership_size(groups) do
    groups
    |> Enum.map(fn %{count: count} -> count end)
    |> Enum.sum()
  end

  # Given a list of groups, return the combined rating (summed)
  @spec sum_group_rating([expanded_group()]) :: non_neg_integer()
  defp sum_group_rating([]), do: 0

  defp sum_group_rating(groups) do
    groups
    |> Enum.map(fn %{group_rating: group_rating} -> group_rating end)
    |> Enum.sum()
  end

  @spec calculate_leaderboard_rating(number(), number()) :: number()
  def calculate_leaderboard_rating(skill, uncertainty) do
    max(skill - 3 * uncertainty, 0)
  end

  @spec balance_group([T.userid()], String.t() | non_neg_integer()) :: number()
  def balance_group(userids, rating_type) do
    userids
    |> Enum.map(fn userid ->
      get_user_balance_rating_value(userid, rating_type)
    end)
    |> balance_group_by_ratings
  end

  @spec balance_group_by_ratings([number()]) :: number()
  def balance_group_by_ratings(ratings) do
    count = Enum.count(ratings)
    sum = Enum.sum(ratings)
    mean = sum / count
    stdev = Statistics.stdev(ratings)

    _method1 =
      ratings
      |> Enum.map(fn r -> max(r, mean) end)
      |> Enum.sum()

    _method2 = sum + stdev * count
    _method3 = sum + Enum.max(ratings)
    _method4 = sum + mean
    _highest_rank = Enum.max(ratings) * count

    sum
  end

  # Stage one, filter out players notably better/worse than the party
  @spec find_comparable_group(expanded_group(), [expanded_group()], list()) ::
          :no_possible_players | :no_possible_combinations | expanded_group()
  defp find_comparable_group(group, solo_players, opts) do
    rating_lower_bound =
      Enum.min(group.ratings) - (opts[:rating_lower_boundary] || @rating_lower_boundary)

    rating_upper_bound =
      Enum.max(group.ratings) + (opts[:rating_upper_boundary] || @rating_upper_boundary)

    possible_players =
      solo_players
      |> Enum.filter(fn solo ->
        solo.group_rating > rating_lower_bound or solo.group_rating < rating_upper_bound
      end)

    if Enum.count(possible_players) < group.count do
      :no_possible_players
    else
      filter_down_possibles(group, possible_players, opts)
    end
  end

  # Now we've trimmed our playerlist a bit lets check out the different combinations
  @spec filter_down_possibles(expanded_group(), [expanded_group()], list()) ::
          :no_possible_combinations | expanded_group()
  defp filter_down_possibles(group, possible_players, opts) do
    group_mean = Enum.sum(group.ratings) / Enum.count(group.ratings)
    group_stddev = Statistics.stdev(group.ratings)

    sorted_possible_players =
      possible_players
      |> Enum.sort_by(fn g -> Enum.count(g.members) end, &>=/2)

    all_combinations =
      make_combinations(group.count, sorted_possible_players)

      # Filter out bad data (parties can cause bad group sizes)
      |> Stream.filter(fn members ->
        total_count =
          members
          |> Enum.map(fn g -> g.count end)
          |> Enum.sum()

        cond do
          total_count > group.count -> false
          true -> true
        end
      end)

      # This part we are getting the relevant stat info to filter on
      |> Stream.map(fn members ->
        member_ratings = Enum.map(members, fn %{group_rating: group_rating} -> group_rating end)

        members_mean = Enum.sum(member_ratings) / group.count
        members_stddev = Statistics.stdev(member_ratings)

        mean_diff = abs(group_mean - members_mean)
        stddev_diff = abs(group_stddev - members_stddev)

        {members, mean_diff, stddev_diff}
      end)

      # We now filter on differences in mean and stddev
      |> Stream.filter(fn {_members, mean_diff, stddev_diff} ->
        cond do
          mean_diff > (opts[:mean_diff_max] || @mean_diff_max) -> false
          stddev_diff > (opts[:stddev_diff_max] || @stddev_diff_max) -> false
          true -> true
        end
      end)

      # Finally we sort
      |> Enum.sort_by(
        fn
          {_members, mean_diff, stddev_diff} -> {mean_diff * stddev_diff, mean_diff, stddev_diff}
        end,
        &<=/2
      )

    case all_combinations do
      [] ->
        :no_possible_combinations

      _ ->
        {selected_group, _, _} = hd(all_combinations)

        # Now turn a list of groups into one group
        selected_group
        |> Enum.reduce(%{members: [], ratings: [], count: 0, group_rating: 0}, fn solo, acc ->
          %{
            members: acc.members ++ solo.members,
            ratings: acc.ratings ++ solo.ratings,
            count: acc.count + solo.count,
            group_rating: acc.group_rating + solo.group_rating
          }
        end)
    end
  end

  # First argument is the size of each combination
  # Second is the list of items to make a combination from
  @spec make_combinations(integer(), list) :: [list]
  defp make_combinations(0, _), do: [[]]
  defp make_combinations(_, []), do: []

  defp make_combinations(n, [x | xs]) do
    if n < 0 do
      [[]]
    else
      for(y <- make_combinations(n - x.count, xs), do: [x | y]) ++ make_combinations(n, xs)
    end
  end
end
