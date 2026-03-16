defmodule SymphonyElixir.SkillRuntime do
  @moduledoc """
  Adapter boundary for skill-runtime context provided to a prompt/run.
  """

  alias SymphonyElixir.Linear.Issue

  @callback prompt_context(Issue.t(), Path.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}

  @spec prompt_context(Issue.t(), Path.t() | nil, keyword()) :: map()
  def prompt_context(%Issue{} = issue, workspace, opts \\ []) do
    adapter = Keyword.get(opts, :skill_runtime, SymphonyElixir.SkillRuntime.Noop)

    case adapter.prompt_context(issue, workspace, opts) do
      {:ok, %{} = context} -> context
      {:ok, nil} -> %{present: false, entries: []}
      {:error, reason} -> raise RuntimeError, "skill_runtime_error: #{inspect(reason)}"
    end
  end
end
