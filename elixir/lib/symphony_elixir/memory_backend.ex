defmodule SymphonyElixir.MemoryBackend do
  @moduledoc """
  Adapter boundary for optional memory context injected into an issue run.
  """

  alias SymphonyElixir.Linear.Issue

  @callback prompt_context(Issue.t(), Path.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}

  @spec prompt_context(Issue.t(), Path.t() | nil, keyword()) :: map()
  def prompt_context(%Issue{} = issue, workspace, opts \\ []) do
    adapter = Keyword.get(opts, :memory_backend, SymphonyElixir.MemoryBackend.Noop)

    case adapter.prompt_context(issue, workspace, opts) do
      {:ok, %{} = context} -> context
      {:ok, nil} -> %{present: false}
      {:error, reason} -> raise RuntimeError, "memory_backend_error: #{inspect(reason)}"
    end
  end
end
