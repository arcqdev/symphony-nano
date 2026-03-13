defmodule SymphonyElixir.AgentRunner do
  @moduledoc """
  Executes a single Linear issue in its workspace with a configured agent backend.
  """

  require Logger
  alias SymphonyElixir.AgentBackend
  alias SymphonyElixir.{Config, Linear.Issue, PromptBuilder, StageRouting, Tracker, Workspace}

  @type worker_host :: String.t() | nil

  @spec run(map(), pid() | nil, keyword()) :: :ok | no_return()
  def run(issue, codex_update_recipient \\ nil, opts \\ []) do
    worker_hosts =
      candidate_worker_hosts(Keyword.get(opts, :worker_host), Config.settings!().worker.ssh_hosts)

    Logger.info("Starting agent run for #{issue_context(issue)} worker_hosts=#{inspect(worker_hosts_for_log(worker_hosts))}")

    case run_on_worker_hosts(issue, codex_update_recipient, opts, worker_hosts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("Agent run failed for #{issue_context(issue)}: #{inspect(reason)}")
        raise RuntimeError, "Agent run failed for #{issue_context(issue)}: #{inspect(reason)}"
    end
  end

  defp run_on_worker_hosts(issue, codex_update_recipient, opts, [worker_host | rest]) do
    case run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
      :ok ->
        :ok

      {:error, reason} when rest != [] ->
        Logger.warning("Agent run failed for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)} reason=#{inspect(reason)}; trying next worker host")
        run_on_worker_hosts(issue, codex_update_recipient, opts, rest)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_on_worker_hosts(_issue, _codex_update_recipient, _opts, []), do: {:error, :no_worker_hosts_available}

  defp run_on_worker_host(issue, codex_update_recipient, opts, worker_host) do
    Logger.info("Starting worker attempt for #{issue_context(issue)} worker_host=#{worker_host_for_log(worker_host)}")

    case Workspace.create_for_issue(issue, worker_host) do
      {:ok, workspace} ->
        try do
          with :ok <- Workspace.run_before_run_hook(workspace, issue, worker_host) do
            run_agent_turns(workspace, issue, codex_update_recipient, opts, worker_host)
          end
        after
          Workspace.run_after_run_hook(workspace, issue, worker_host)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp codex_message_handler(recipient, issue, stage, backend) do
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

  defp run_agent_turns(workspace, issue, codex_update_recipient, opts, worker_host) do
    routes = Config.routed_stages(issue)
    backend_module = Keyword.get(opts, :agent_backend, AgentBackend)
    tracker_module = Keyword.get(opts, :tracker, Tracker)

    if StageRouting.stage_labeled?(routes) do
      run_routed_stage_turns(
        routes,
        workspace,
        issue,
        codex_update_recipient,
        opts,
        worker_host,
        backend_module,
        tracker_module
      )
    else
      [%{backend: backend}] = routes
      send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace, nil, backend)
      run_default_backend_turns(workspace, issue, codex_update_recipient, opts, worker_host, backend_module, backend)
    end
  end

  defp run_default_backend_turns(workspace, issue, codex_update_recipient, opts, worker_host, backend_module, backend) do
    max_turns = Keyword.get(opts, :max_turns, Config.settings!().agent.max_turns)
    issue_state_fetcher = Keyword.get(opts, :issue_state_fetcher, &Tracker.fetch_issue_states_by_ids/1)

    with {:ok, session} <- backend_module.start_session(workspace, worker_host: worker_host, backend: backend) do
      try do
        do_run_default_backend_turns(
          session,
          workspace,
          issue,
          codex_update_recipient,
          opts,
          issue_state_fetcher,
          1,
          max_turns,
          backend_module,
          backend
        )
      after
        backend_module.stop_session(session)
      end
    end
  end

  defp run_routed_stage_turns(
         routes,
         workspace,
         issue,
         codex_update_recipient,
         opts,
         worker_host,
         backend_module,
         tracker_module
       ) do
    total_stages = length(routes)

    Enum.reduce_while(Enum.with_index(routes, 1), :ok, fn {%{stage: stage, backend: backend}, stage_index}, :ok ->
      send_worker_runtime_info(codex_update_recipient, issue, worker_host, workspace, stage, backend)

      case run_single_stage_turn(
             workspace,
             issue,
             codex_update_recipient,
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

        {:error, {:backend_unavailable, "claude-code", reason}} ->
          handle_backend_unavailable(issue, stage, backend, reason, codex_update_recipient, tracker_module)
          {:halt, :ok}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp run_single_stage_turn(
         workspace,
         issue,
         codex_update_recipient,
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
                   on_message: codex_message_handler(codex_update_recipient, issue, stage, backend),
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

  defp do_run_default_backend_turns(
         app_session,
         workspace,
         issue,
         codex_update_recipient,
         opts,
         issue_state_fetcher,
         turn_number,
         max_turns,
         backend_module,
         backend
       ) do
    prompt = build_turn_prompt(issue, opts, turn_number, max_turns)

    with {:ok, turn_session} <-
           backend_module.run_turn(
             app_session,
             prompt,
             issue,
             on_message: codex_message_handler(codex_update_recipient, issue, nil, backend),
             backend: backend
           ) do
      Logger.info("Completed agent run for #{issue_context(issue)} session_id=#{turn_session[:session_id]} workspace=#{workspace} turn=#{turn_number}/#{max_turns} backend=#{backend}")

      case continue_with_issue?(issue, issue_state_fetcher) do
        {:continue, refreshed_issue} when turn_number < max_turns ->
          Logger.info("Continuing agent run for #{issue_context(refreshed_issue)} after normal turn completion turn=#{turn_number}/#{max_turns} backend=#{backend}")

          do_run_default_backend_turns(
            app_session,
            workspace,
            refreshed_issue,
            codex_update_recipient,
            opts,
            issue_state_fetcher,
            turn_number + 1,
            max_turns,
            backend_module,
            backend
          )

        {:continue, refreshed_issue} ->
          Logger.info("Reached agent.max_turns for #{issue_context(refreshed_issue)} with issue still active; returning control to orchestrator backend=#{backend}")

          :ok

        {:done, _refreshed_issue} ->
          :ok

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp build_turn_prompt(issue, opts, 1, _max_turns), do: PromptBuilder.build_prompt(issue, opts)

  defp build_turn_prompt(_issue, _opts, turn_number, max_turns) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but the Linear issue is still in an active state.
    - This is continuation turn ##{turn_number} of #{max_turns} for the current agent run.
    - Resume from the current workspace and workpad state instead of restarting from scratch.
    - The original task instructions and prior turn context are already present in this thread, so do not restate them before acting.
    - Focus on the remaining ticket work and do not end the turn while the issue stays active unless you are truly blocked.
    """
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

  defp annotate_message(message, stage, backend) when is_map(message) do
    message
    |> maybe_put_message_value(:stage, stage)
    |> maybe_put_message_value(:backend, backend)
  end

  defp annotate_message(message, _stage, _backend), do: message

  defp maybe_put_message_value(message, _key, nil), do: message

  defp maybe_put_message_value(message, key, value) when is_map(message) do
    case Map.get(message, key) do
      nil -> Map.put(message, key, value)
      _ -> message
    end
  end

  defp continue_with_issue?(%Issue{id: issue_id} = issue, issue_state_fetcher) when is_binary(issue_id) do
    case issue_state_fetcher.([issue_id]) do
      {:ok, [%Issue{} = refreshed_issue | _]} ->
        if active_issue_state?(refreshed_issue.state) do
          {:continue, refreshed_issue}
        else
          {:done, refreshed_issue}
        end

      {:ok, []} ->
        {:done, issue}

      {:error, reason} ->
        {:error, {:issue_state_refresh_failed, reason}}
    end
  end

  defp continue_with_issue?(issue, _issue_state_fetcher), do: {:done, issue}

  defp active_issue_state?(state_name) when is_binary(state_name) do
    normalized_state = normalize_issue_state(state_name)

    Config.settings!().tracker.active_states
    |> Enum.any?(fn active_state -> normalize_issue_state(active_state) == normalized_state end)
  end

  defp active_issue_state?(_state_name), do: false

  defp candidate_worker_hosts(nil, []), do: [nil]

  defp candidate_worker_hosts(preferred_host, configured_hosts) when is_list(configured_hosts) do
    hosts =
      configured_hosts
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    case preferred_host do
      host when is_binary(host) and host != "" ->
        [host | Enum.reject(hosts, &(&1 == host))]

      _ when hosts == [] ->
        [nil]

      _ ->
        hosts
    end
  end

  defp worker_hosts_for_log(worker_hosts) do
    Enum.map(worker_hosts, &worker_host_for_log/1)
  end

  defp worker_host_for_log(nil), do: "local"
  defp worker_host_for_log(worker_host), do: worker_host

  defp normalize_issue_state(state_name) when is_binary(state_name) do
    state_name
    |> String.trim()
    |> String.downcase()
  end

  defp issue_context(%Issue{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end
end
