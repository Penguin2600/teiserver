defmodule Teiserver.Tachyon.Responses.LobbyHost.CloseResponse do
  @moduledoc """
  Updated status response - https://github.com/beyond-all-reason/tachyon/blob/master/src/schema/lobby_host.ts
  """

  alias Teiserver.Data.Types, as: T

  @spec execute() :: {T.tachyon_command(), T.tachyon_object()}
  def execute() do
    object = %{}

    {"lobby_host/close/response", object}
  end
end
