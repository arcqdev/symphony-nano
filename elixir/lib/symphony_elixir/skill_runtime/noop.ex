defmodule SymphonyElixir.SkillRuntime.Noop do
  @moduledoc """
  Default skill runtime adapter that contributes no extra prompt context.
  """

  @behaviour SymphonyElixir.SkillRuntime

  @impl true
  def prompt_context(_issue, _workspace, _opts) do
    {:ok, %{present: false, entries: []}}
  end
end
