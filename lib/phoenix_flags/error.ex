defmodule PhoenixFlags.Error do
  @moduledoc """
  Raised when PhoenixFlags encounters a configuration or validation error.
  """
  defexception [:message]
end
