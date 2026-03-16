defmodule SymphonyElixir.MemoryBackend.Noop do
  @moduledoc """
  Default memory backend adapter that contributes no extra prompt context.
  """

  @behaviour SymphonyElixir.MemoryBackend

  @impl true
  def prompt_context(_issue, _workspace, _opts) do
    {:ok, %{present: false}}
  end
end
