defmodule Teiserver.Telemetry.GameEventTypeLib do
  use CentralWeb, :library
  alias Teiserver.Telemetry.GameEventType

  # Functions
  @spec icon :: String.t()
  def icon, do: "fa-regular fa-???"

  @spec colours :: atom
  def colours, do: :default

  # Queries
  @spec query_game_event_types() :: Ecto.Query.t()
  def query_game_event_types do
    from(game_event_types in GameEventType)
  end

  @spec search(Ecto.Query.t(), Map.t() | nil) :: Ecto.Query.t()
  def search(query, nil), do: query

  def search(query, params) do
    params
    |> Enum.reduce(query, fn {key, value}, query_acc ->
      _search(query_acc, key, value)
    end)
  end

  @spec _search(Ecto.Query.t(), Atom.t(), any()) :: Ecto.Query.t()
  def _search(query, _, ""), do: query
  def _search(query, _, nil), do: query

  def _search(query, :id, id) do
    from game_event_types in query,
      where: game_event_types.id == ^id
  end

  def _search(query, :name, name) do
    from game_event_types in query,
      where: game_event_types.name == ^name
  end

  def _search(query, :id_list, id_list) do
    from game_event_types in query,
      where: game_event_types.id in ^id_list
  end

  def _search(query, :basic_search, ref) do
    ref_like = "%" <> String.replace(ref, "*", "%") <> "%"

    from game_event_types in query,
      where: ilike(game_event_types.name, ^ref_like)
  end

  @spec order_by(Ecto.Query.t(), String.t() | nil) :: Ecto.Query.t()
  def order_by(query, nil), do: query

  def order_by(query, "Name (A-Z)") do
    from game_event_types in query,
      order_by: [asc: game_event_types.name]
  end

  def order_by(query, "Name (Z-A)") do
    from game_event_types in query,
      order_by: [desc: game_event_types.name]
  end

  def order_by(query, "ID (Lowest first)") do
    from property_types in query,
      order_by: [asc: property_types.id]
  end

  def order_by(query, "ID (Highest first)") do
    from property_types in query,
      order_by: [desc: property_types.id]
  end

  @spec preload(Ecto.Query.t(), List.t() | nil) :: Ecto.Query.t()
  def preload(query, nil), do: query

  def preload(query, _preloads) do
    # query = if :things in preloads, do: _preload_things(query), else: query
    query
  end

  # def _preload_things(query) do
  #   from game_event_types in query,
  #     left_join: things in assoc(game_event_types, :things),
  #     preload: [things: things]
  # end
end
