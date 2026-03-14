defmodule SymphonyElixir.AgentRunner.StageRun do
  @moduledoc false

  require Logger

  alias SymphonyElixir.{Linear.Issue, PromptBuilder}

  @spec run([map()], String.t(), map(), pid() | nil, keyword(), String.t() | nil, module(), module()) ::
          :ok | {:error, term()}
  def run(routes, workspace, issue, recipient, opts, worker_host, backend_module, tracker_module) do
    total_stages = length(routes)

    Enum.reduce_while(Enum.with_index(routes, 1), :ok, fn {%{stage: stage, backend: backend}, stage_index}, :ok ->
      send_worker_runtime_info(recipient, issue, worker_host, workspace, stage, backend)

      case run_single_stage_turn(
             workspace,
             issue,
             recipient,
             opts,
             worker_host,
             backend_module,
             stage,
             backend,
             stage_index,
             total_stages,
             routes
           ) do
        :ok ->
          {:cont, :ok}

        {:error, {:backend_unavailable, _backend_name, reason}} ->
          handle_backend_unavailable(issue, stage, backend, reason, recipient, tracker_module)
          {:halt, :ok}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  @spec annotate_message(term(), String.t() | nil, String.t() | nil) :: term()
  def annotate_message(message, stage, backend) when is_map(message) do
    message
    |> maybe_put_message_value(:stage, stage)
    |> maybe_put_message_value(:backend, backend)
  end

  def annotate_message(message, _stage, _backend), do: message

  defp run_single_stage_turn(
         workspace,
         issue,
         recipient,
         opts,
         worker_host,
         backend_module,
         stage,
         backend,
         stage_index,
         total_stages,
         routes
       ) do
    prompt = build_stage_prompt(issue, opts, stage, backend, stage_index, total_stages, routes)

    case backend_module.start_session(workspace, worker_host: worker_host, backend: backend, stage: stage) do
      {:ok, session} ->
        try do
          with {:ok, turn_session} <-
                 backend_module.run_turn(
                   session,
                   prompt,
                   issue,
                   on_message: stage_message_handler(recipient, issue, stage, backend),
                   backend: backend
                 ) do
            Logger.info(
              "Completed agent stage run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} stage=#{stage} backend=#{backend} stage_position=#{stage_index}/#{total_stages}"
            )

            :ok
          end
        after
          backend_module.stop_session(session)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_stage_prompt(issue, opts, stage, backend, stage_index, total_stages, routes) do
    route_summary =
      routes
      |> Enum.map_join(" -> ", fn %{stage: route_stage, backend: route_backend} ->
        "#{route_stage}(#{route_backend})"
      end)

    stage_guidance =
      if stage_index < total_stages do
        """
        Symphony runtime stage routing:

        - Current stage: #{stage}
        - Selected backend: #{backend}
        - Stage #{stage_index} of #{total_stages}: #{route_summary}
        - Execute only the `#{stage}` stage in this turn.
        - Update the workspace and workpad for the completed `#{stage}` stage.
        - Do not perform other stages or final landing in this turn.
        """
      else
        """
        Symphony runtime stage routing:

        - Current stage: #{stage}
        - Selected backend: #{backend}
        - Stage #{stage_index} of #{total_stages}: #{route_summary}
        - Execute the `#{stage}` stage in this turn.
        - After the `#{stage}` stage is complete, continue through and complete Stage 3 validation and landing.
        - Do not revisit earlier completed stages except for strictly necessary fixes.
        """
      end

    stage_guidance <> "\n\n" <> PromptBuilder.build_prompt(issue, opts)
  end

  defp handle_backend_unavailable(issue, stage, backend, reason, recipient, tracker_module) do
    emit_backend_unavailable(recipient, issue, stage, backend, reason)

    if is_binary(issue.id) do
      blocker_comment = backend_unavailable_comment(issue, stage, backend, reason)
      :ok = tracker_module.create_comment(issue.id, blocker_comment)
      :ok = tracker_module.update_issue_state(issue.id, "Rework")
    end

    :ok
  end

  defp emit_backend_unavailable(recipient, issue, stage, backend, reason) do
    send_codex_update(recipient, issue, %{
      event: :backend_unavailable,
      backend: backend,
      stage: stage,
      reason: reason,
      timestamp: DateTime.utc_now()
    })
  end

  defp backend_unavailable_comment(issue, stage, backend, reason) do
    """
    Blocked: required backend `#{backend}` is unavailable for the `#{stage}` stage.

    Issue: #{issue.identifier}
    Action taken: moved to Rework so a human can unblock the runtime.
    Reason: #{inspect(reason)}

    Symphony did not fall back to Codex for this routed stage.
    """
    |> String.trim()
  end

  defp stage_message_handler(recipient, issue, stage, backend) do
    fn message ->
      send_codex_update(recipient, issue, annotate_message(message, stage, backend))
    end
  end

  defp send_codex_update(recipient, %Issue{id: issue_id}, message)
       when is_binary(issue_id) and is_pid(recipient) do
    send(recipient, {:codex_worker_update, issue_id, message})
    :ok
  end

  defp send_codex_update(_recipient, _issue, _message), do: :ok

  defp send_worker_runtime_info(
         recipient,
         %Issue{id: issue_id},
         worker_host,
         workspace,
         stage,
         backend
       )
       when is_binary(issue_id) and is_pid(recipient) and is_binary(workspace) do
    send(
      recipient,
      {:worker_runtime_info, issue_id,
       %{
         worker_host: worker_host,
         workspace_path: workspace,
         stage: stage,
         backend: backend
       }}
    )

    :ok
  end

  defp send_worker_runtime_info(_recipient, _issue, _worker_host, _workspace, _stage, _backend), do: :ok

  defp maybe_put_message_value(message, _key, nil), do: message

  defp maybe_put_message_value(message, key, value) when is_map(message) do
    case Map.get(message, key) do
      nil -> Map.put(message, key, value)
      _ -> message
    end
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
