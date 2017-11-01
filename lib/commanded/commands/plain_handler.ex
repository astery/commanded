defmodule Commanded.Commands.PlainHandler do
  @moduledoc """
  Defines the behaviour a command handler must implement to support plain command dispatch.
  """

  @type command :: struct()
  @type assigns :: map()
  @type reason :: term()

  @doc """
  Run the given command to the aggregate root.

  Aggreagate can be extracted by hand in command or via middleware layer.
  Pipeline assigns available for this reason and for passing external dependencies as second argument.

  Commands should return :ok.
  Queries should return {:ok, result}

  You should return `{:error, reason}` on failure.
  """
  @callback handle(command, assigns) :: :ok | {:ok, any()} | {:error, reason}
end
