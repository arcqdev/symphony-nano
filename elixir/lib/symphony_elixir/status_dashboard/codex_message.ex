defmodule SymphonyElixir.StatusDashboard.CodexMessage do
  @moduledoc false

  alias SymphonyElixir.StatusDashboard.CodexMessageUtils, as: Utils

  @doc false
  @spec humanize_codex_message(term()) :: String.t()
  def humanize_codex_message(nil), do: "no codex message yet"

  def humanize_codex_message(%{event: event, message: message}) do
    payload = unwrap_codex_message_payload(message)

    (humanize_codex_event(event, message, payload) || humanize_codex_payload(payload))
    |> Utils.truncate(140)
  end

  def humanize_codex_message(%{message: message}) do
    message
    |> unwrap_codex_message_payload()
    |> humanize_codex_payload()
    |> Utils.truncate(140)
  end

  def humanize_codex_message(message) do
    message
    |> unwrap_codex_message_payload()
    |> humanize_codex_payload()
    |> Utils.truncate(140)
  end

  defp humanize_codex_event(:session_started, _message, payload) do
    session_id = Utils.map_value(payload, ["session_id", :session_id])
    if(is_binary(session_id), do: "session started (#{session_id})", else: "session started")
  end

  defp humanize_codex_event(:turn_input_required, _message, _payload),
    do: "turn blocked: waiting for user input"

  defp humanize_codex_event(:approval_auto_approved, message, payload) do
    method =
      Utils.map_value(payload, ["method", :method]) ||
        Utils.map_path(message, ["payload", "method"]) ||
        Utils.map_path(message, [:payload, :method])

    decision = Utils.map_value(message, ["decision", :decision])

    base =
      if is_binary(method) do
        "#{humanize_codex_method(method, payload)} (auto-approved)"
      else
        "approval request auto-approved"
      end

    if is_binary(decision), do: "#{base}: #{decision}", else: base
  end

  defp humanize_codex_event(:tool_input_auto_answered, message, payload) do
    answer = Utils.map_value(message, ["answer", :answer])

    base =
      case humanize_codex_method("item/tool/requestUserInput", payload) do
        nil -> "tool input auto-answered"
        text -> "#{text} (auto-answered)"
      end

    if is_binary(answer), do: "#{base}: #{Utils.inline_text(answer)}", else: base
  end

  defp humanize_codex_event(:tool_call_completed, _message, payload),
    do: humanize_dynamic_tool_event("dynamic tool call completed", payload)

  defp humanize_codex_event(:tool_call_failed, _message, payload),
    do: humanize_dynamic_tool_event("dynamic tool call failed", payload)

  defp humanize_codex_event(:unsupported_tool_call, _message, payload),
    do: humanize_dynamic_tool_event("unsupported dynamic tool call rejected", payload)

  defp humanize_codex_event(:turn_ended_with_error, message, _payload),
    do: "turn ended with error: #{format_reason(message)}"

  defp humanize_codex_event(:startup_failed, message, _payload),
    do: "startup failed: #{format_reason(message)}"

  defp humanize_codex_event(:turn_failed, _message, payload),
    do: humanize_codex_method("turn/failed", payload)

  defp humanize_codex_event(:turn_cancelled, _message, _payload), do: "turn cancelled"
  defp humanize_codex_event(:malformed, _message, _payload), do: "malformed JSON event from codex"
  defp humanize_codex_event(_event, _message, _payload), do: nil

  defp unwrap_codex_message_payload(%{} = message) do
    cond do
      is_binary(Utils.map_value(message, ["method", :method])) -> message
      is_binary(Utils.map_value(message, ["session_id", :session_id])) -> message
      is_binary(Utils.map_value(message, ["reason", :reason])) -> message
      true -> Utils.map_value(message, ["payload", :payload]) || message
    end
  end

  defp unwrap_codex_message_payload(message), do: message

  defp humanize_codex_payload(%{} = payload) do
    case Utils.map_value(payload, ["method", :method]) do
      method when is_binary(method) ->
        humanize_codex_method(method, payload)

      _ ->
        cond do
          is_binary(Utils.map_value(payload, ["session_id", :session_id])) ->
            "session started (#{Utils.map_value(payload, ["session_id", :session_id])})"

          match?(%{"error" => _}, payload) ->
            "error: #{format_error_value(Map.get(payload, "error"))}"

          true ->
            payload
            |> inspect(pretty: true, limit: 30)
            |> String.replace("\n", " ")
            |> sanitize_ansi_and_control_bytes()
            |> String.trim()
        end
    end
  end

  defp humanize_codex_payload(payload) when is_binary(payload) do
    payload
    |> String.replace("\n", " ")
    |> sanitize_ansi_and_control_bytes()
    |> String.trim()
  end

  defp humanize_codex_payload(payload) do
    payload
    |> inspect(pretty: true, limit: 20)
    |> String.replace("\n", " ")
    |> sanitize_ansi_and_control_bytes()
    |> String.trim()
  end

  defp sanitize_ansi_and_control_bytes(value) when is_binary(value) do
    value
    |> String.replace(~r/\x1B\[[0-9;]*[A-Za-z]/, "")
    |> String.replace(~r/\x1B./, "")
    |> String.replace(~r/[\x00-\x1F\x7F]/, "")
  end

  defp humanize_codex_method("thread/started", payload) do
    thread_id = Utils.map_path(payload, ["params", "thread", "id"]) || Utils.map_path(payload, [:params, :thread, :id])
    if(is_binary(thread_id), do: "thread started (#{thread_id})", else: "thread started")
  end

  defp humanize_codex_method("turn/started", payload) do
    turn_id = Utils.map_path(payload, ["params", "turn", "id"]) || Utils.map_path(payload, [:params, :turn, :id])
    if(is_binary(turn_id), do: "turn started (#{turn_id})", else: "turn started")
  end

  defp humanize_codex_method("turn/completed", payload) do
    status =
      Utils.map_path(payload, ["params", "turn", "status"]) ||
        Utils.map_path(payload, [:params, :turn, :status]) ||
        "completed"

    usage =
      Utils.map_path(payload, ["params", "usage"]) ||
        Utils.map_path(payload, [:params, :usage]) ||
        Utils.map_path(payload, ["params", "tokenUsage"]) ||
        Utils.map_path(payload, [:params, :tokenUsage]) ||
        Utils.map_value(payload, ["usage", :usage])

    usage_suffix =
      case format_usage_counts(usage) do
        nil -> ""
        usage_text -> " (#{usage_text})"
      end

    "turn completed (#{status})#{usage_suffix}"
  end

  defp humanize_codex_method("turn/failed", payload) do
    error_message =
      Utils.map_path(payload, ["params", "error", "message"]) ||
        Utils.map_path(payload, [:params, :error, :message])

    if is_binary(error_message), do: "turn failed: #{error_message}", else: "turn failed"
  end

  defp humanize_codex_method("turn/cancelled", _payload), do: "turn cancelled"

  defp humanize_codex_method("turn/diff/updated", payload) do
    diff =
      Utils.map_path(payload, ["params", "diff"]) ||
        Utils.map_path(payload, [:params, :diff]) ||
        ""

    if is_binary(diff) and diff != "" do
      line_count = diff |> String.split("\n", trim: true) |> length()
      "turn diff updated (#{line_count} lines)"
    else
      "turn diff updated"
    end
  end

  defp humanize_codex_method("turn/plan/updated", payload) do
    plan_entries =
      Utils.map_path(payload, ["params", "plan"]) ||
        Utils.map_path(payload, [:params, :plan]) ||
        Utils.map_path(payload, ["params", "steps"]) ||
        Utils.map_path(payload, [:params, :steps]) ||
        Utils.map_path(payload, ["params", "items"]) ||
        Utils.map_path(payload, [:params, :items]) ||
        []

    if is_list(plan_entries), do: "plan updated (#{length(plan_entries)} steps)", else: "plan updated"
  end

  defp humanize_codex_method("thread/tokenUsage/updated", payload) do
    usage =
      Utils.map_path(payload, ["params", "tokenUsage", "total"]) ||
        Utils.map_path(payload, [:params, :tokenUsage, :total]) ||
        Utils.map_value(payload, ["usage", :usage])

    case format_usage_counts(usage) do
      nil -> "thread token usage updated"
      usage_text -> "thread token usage updated (#{usage_text})"
    end
  end

  defp humanize_codex_method("item/started", payload), do: humanize_item_lifecycle("started", payload)
  defp humanize_codex_method("item/completed", payload), do: humanize_item_lifecycle("completed", payload)
  defp humanize_codex_method("item/agentMessage/delta", payload), do: humanize_streaming_event("agent message streaming", payload)
  defp humanize_codex_method("item/plan/delta", payload), do: humanize_streaming_event("plan streaming", payload)

  defp humanize_codex_method("item/reasoning/summaryTextDelta", payload),
    do: humanize_streaming_event("reasoning summary streaming", payload)

  defp humanize_codex_method("item/reasoning/summaryPartAdded", payload),
    do: humanize_streaming_event("reasoning summary section added", payload)

  defp humanize_codex_method("item/reasoning/textDelta", payload),
    do: humanize_streaming_event("reasoning text streaming", payload)

  defp humanize_codex_method("item/commandExecution/outputDelta", payload),
    do: humanize_streaming_event("command output streaming", payload)

  defp humanize_codex_method("item/fileChange/outputDelta", payload),
    do: humanize_streaming_event("file change output streaming", payload)

  defp humanize_codex_method("item/commandExecution/requestApproval", payload) do
    command = extract_command(payload)
    if(is_binary(command), do: "command approval requested (#{command})", else: "command approval requested")
  end

  defp humanize_codex_method("item/fileChange/requestApproval", payload) do
    change_count = Utils.map_path(payload, ["params", "fileChangeCount"]) || Utils.map_path(payload, ["params", "changeCount"])

    if is_integer(change_count) and change_count > 0 do
      "file change approval requested (#{change_count} files)"
    else
      "file change approval requested"
    end
  end

  defp humanize_codex_method("item/tool/requestUserInput", payload) do
    question =
      Utils.map_path(payload, ["params", "question"]) ||
        Utils.map_path(payload, ["params", "prompt"]) ||
        Utils.map_path(payload, [:params, :question]) ||
        Utils.map_path(payload, [:params, :prompt])

    if is_binary(question) and String.trim(question) != "" do
      "tool requires user input: #{Utils.inline_text(question)}"
    else
      "tool requires user input"
    end
  end

  defp humanize_codex_method("tool/requestUserInput", payload),
    do: humanize_codex_method("item/tool/requestUserInput", payload)

  defp humanize_codex_method("account/updated", payload) do
    auth_mode =
      Utils.map_path(payload, ["params", "authMode"]) ||
        Utils.map_path(payload, [:params, :authMode]) ||
        "unknown"

    "account updated (auth #{auth_mode})"
  end

  defp humanize_codex_method("account/rateLimits/updated", payload) do
    rate_limits = Utils.map_path(payload, ["params", "rateLimits"]) || Utils.map_path(payload, [:params, :rateLimits])
    "rate limits updated: #{format_rate_limits_summary(rate_limits)}"
  end

  defp humanize_codex_method("account/chatgptAuthTokens/refresh", _payload),
    do: "account auth token refresh requested"

  defp humanize_codex_method("item/tool/call", payload) do
    tool = dynamic_tool_name(payload)
    if is_binary(tool) and String.trim(tool) != "", do: "dynamic tool call requested (#{tool})", else: "dynamic tool call requested"
  end

  defp humanize_codex_method(<<"codex/event/", suffix::binary>>, payload),
    do: humanize_codex_wrapper_event(suffix, payload)

  defp humanize_codex_method(method, payload) do
    msg_type =
      Utils.map_path(payload, ["params", "msg", "type"]) ||
        Utils.map_path(payload, [:params, :msg, :type])

    if is_binary(msg_type), do: "#{method} (#{msg_type})", else: method
  end

  defp humanize_dynamic_tool_event(base, payload) do
    case dynamic_tool_name(payload) do
      tool when is_binary(tool) ->
        trimmed = String.trim(tool)
        if(trimmed == "", do: base, else: "#{base} (#{trimmed})")

      _ ->
        base
    end
  end

  defp dynamic_tool_name(payload) do
    Utils.map_path(payload, ["params", "tool"]) ||
      Utils.map_path(payload, ["params", "name"]) ||
      Utils.map_path(payload, [:params, :tool]) ||
      Utils.map_path(payload, [:params, :name])
  end

  defp humanize_item_lifecycle(state, payload) do
    item = Utils.map_path(payload, ["params", "item"]) || Utils.map_path(payload, [:params, :item]) || %{}
    item_type = item |> Utils.map_value(["type", :type]) |> humanize_item_type()
    item_status = Utils.map_value(item, ["status", :status])
    item_id = Utils.map_value(item, ["id", :id])

    details =
      []
      |> append_if_present(short_id(item_id))
      |> append_if_present(humanize_status(item_status))

    detail_suffix = if details == [], do: "", else: " (#{Enum.join(details, ", ")})"
    "item #{state}: #{item_type}#{detail_suffix}"
  end

  defp humanize_codex_wrapper_event("mcp_startup_update", payload) do
    server =
      Utils.map_path(payload, ["params", "msg", "server"]) ||
        Utils.map_path(payload, [:params, :msg, :server]) ||
        "mcp"

    state =
      Utils.map_path(payload, ["params", "msg", "status", "state"]) ||
        Utils.map_path(payload, [:params, :msg, :status, :state]) ||
        "updated"

    "mcp startup: #{server} #{state}"
  end

  defp humanize_codex_wrapper_event("mcp_startup_complete", _payload), do: "mcp startup complete"
  defp humanize_codex_wrapper_event("task_started", _payload), do: "task started"
  defp humanize_codex_wrapper_event("user_message", _payload), do: "user message received"

  defp humanize_codex_wrapper_event("item_started", payload) do
    case wrapper_payload_type(payload) do
      "token_count" -> humanize_codex_wrapper_event("token_count", payload)
      type when is_binary(type) -> "item started (#{humanize_item_type(type)})"
      _ -> "item started"
    end
  end

  defp humanize_codex_wrapper_event("item_completed", payload) do
    case wrapper_payload_type(payload) do
      "token_count" -> humanize_codex_wrapper_event("token_count", payload)
      type when is_binary(type) -> "item completed (#{humanize_item_type(type)})"
      _ -> "item completed"
    end
  end

  defp humanize_codex_wrapper_event("agent_message_delta", payload), do: humanize_streaming_event("agent message streaming", payload)
  defp humanize_codex_wrapper_event("agent_message_content_delta", payload), do: humanize_streaming_event("agent message content streaming", payload)
  defp humanize_codex_wrapper_event("agent_reasoning_delta", payload), do: humanize_streaming_event("reasoning streaming", payload)
  defp humanize_codex_wrapper_event("reasoning_content_delta", payload), do: humanize_streaming_event("reasoning content streaming", payload)
  defp humanize_codex_wrapper_event("agent_reasoning_section_break", _payload), do: "reasoning section break"
  defp humanize_codex_wrapper_event("agent_reasoning", payload), do: humanize_reasoning_update(payload)
  defp humanize_codex_wrapper_event("turn_diff", _payload), do: "turn diff updated"
  defp humanize_codex_wrapper_event("exec_command_begin", payload), do: humanize_exec_command_begin(payload)
  defp humanize_codex_wrapper_event("exec_command_end", payload), do: humanize_exec_command_end(payload)
  defp humanize_codex_wrapper_event("exec_command_output_delta", _payload), do: "command output streaming"
  defp humanize_codex_wrapper_event("mcp_tool_call_begin", _payload), do: "mcp tool call started"
  defp humanize_codex_wrapper_event("mcp_tool_call_end", _payload), do: "mcp tool call completed"

  defp humanize_codex_wrapper_event("token_count", payload) do
    usage = Utils.extract_first_path(payload, Utils.token_usage_paths())

    case format_usage_counts(usage) do
      nil -> "token count update"
      usage_text -> "token count update (#{usage_text})"
    end
  end

  defp humanize_codex_wrapper_event(other, payload) do
    msg_type =
      Utils.map_path(payload, ["params", "msg", "type"]) ||
        Utils.map_path(payload, [:params, :msg, :type])

    if is_binary(msg_type), do: "#{other} (#{msg_type})", else: other
  end

  defp humanize_exec_command_begin(payload) do
    command =
      Utils.map_path(payload, ["params", "msg", "command"]) ||
        Utils.map_path(payload, [:params, :msg, :command]) ||
        Utils.map_path(payload, ["params", "msg", "parsed_cmd"]) ||
        Utils.map_path(payload, [:params, :msg, :parsed_cmd])

    command = normalize_command(command)
    if(is_binary(command), do: command, else: "command started")
  end

  defp humanize_exec_command_end(payload) do
    exit_code =
      Utils.map_path(payload, ["params", "msg", "exit_code"]) ||
        Utils.map_path(payload, [:params, :msg, :exit_code]) ||
        Utils.map_path(payload, ["params", "msg", "exitCode"]) ||
        Utils.map_path(payload, [:params, :msg, :exitCode])

    if is_integer(exit_code), do: "command completed (exit #{exit_code})", else: "command completed"
  end

  defp format_usage_counts(usage) when is_map(usage) do
    input =
      Utils.parse_integer(
        Utils.map_value(usage, [
          "input_tokens",
          :input_tokens,
          "prompt_tokens",
          :prompt_tokens,
          "inputTokens",
          :inputTokens,
          "promptTokens",
          :promptTokens
        ])
      )

    output =
      Utils.parse_integer(
        Utils.map_value(usage, [
          "output_tokens",
          :output_tokens,
          "completion_tokens",
          :completion_tokens,
          "outputTokens",
          :outputTokens,
          "completionTokens",
          :completionTokens
        ])
      )

    total =
      Utils.parse_integer(Utils.map_value(usage, ["total_tokens", :total_tokens, "total", :total, "totalTokens", :totalTokens]))

    parts =
      []
      |> append_usage_part("in", input)
      |> append_usage_part("out", output)
      |> append_usage_part("total", total)

    case parts do
      [] -> nil
      _ -> Enum.join(parts, ", ")
    end
  end

  defp format_usage_counts(_usage), do: nil
  defp append_usage_part(parts, _label, value) when not is_integer(value), do: parts
  defp append_usage_part(parts, label, value), do: parts ++ ["#{label} #{format_count(value)}"]
  defp format_rate_limits_summary(nil), do: "n/a"

  defp format_rate_limits_summary(rate_limits) when is_map(rate_limits) do
    primary = Utils.map_value(rate_limits, ["primary", :primary])
    secondary = Utils.map_value(rate_limits, ["secondary", :secondary])
    primary_text = format_rate_limit_bucket_summary(primary)
    secondary_text = format_rate_limit_bucket_summary(secondary)

    cond do
      primary_text != nil and secondary_text != nil -> "primary #{primary_text}; secondary #{secondary_text}"
      primary_text != nil -> "primary #{primary_text}"
      secondary_text != nil -> "secondary #{secondary_text}"
      true -> "n/a"
    end
  end

  defp format_rate_limits_summary(_rate_limits), do: "n/a"

  defp format_rate_limit_bucket_summary(bucket) when is_map(bucket) do
    used_percent = Utils.map_value(bucket, ["usedPercent", :usedPercent])
    window_mins = Utils.map_value(bucket, ["windowDurationMins", :windowDurationMins])

    cond do
      is_number(used_percent) and is_integer(window_mins) -> "#{used_percent}% / #{window_mins}m"
      is_number(used_percent) -> "#{used_percent}% used"
      true -> nil
    end
  end

  defp format_rate_limit_bucket_summary(_bucket), do: nil
  defp format_error_value(%{"message" => message}) when is_binary(message), do: message
  defp format_error_value(%{message: message}) when is_binary(message), do: message
  defp format_error_value(error), do: inspect(error, limit: 10)

  defp format_reason(message) when is_map(message) do
    case Utils.map_value(message, ["reason", :reason]) do
      nil -> message |> inspect(limit: 10) |> Utils.inline_text()
      reason -> format_error_value(reason)
    end
  end

  defp format_reason(other), do: format_error_value(other)

  defp humanize_streaming_event(label, payload) do
    case extract_delta_preview(payload) do
      nil -> label
      preview -> "#{label}: #{preview}"
    end
  end

  defp humanize_reasoning_update(payload) do
    case extract_reasoning_focus(payload) do
      nil -> "reasoning update"
      focus -> "reasoning update: #{focus}"
    end
  end

  defp extract_reasoning_focus(payload) do
    value = Utils.extract_first_path(payload, Utils.reasoning_focus_paths())

    if is_binary(value) do
      trimmed = String.trim(value)
      if(trimmed == "", do: nil, else: Utils.inline_text(trimmed))
    else
      nil
    end
  end

  defp extract_delta_preview(payload) do
    delta = Utils.extract_first_path(payload, Utils.delta_paths())

    case delta do
      value when is_binary(value) ->
        trimmed = String.trim(value)
        if(trimmed == "", do: nil, else: Utils.inline_text(trimmed))

      _ ->
        nil
    end
  end

  defp extract_command(payload) do
    payload
    |> Utils.map_path(["params", "parsedCmd"])
    |> fallback_command(payload)
    |> normalize_command()
  end

  defp fallback_command(nil, payload) do
    Utils.map_path(payload, ["params", "command"]) ||
      Utils.map_path(payload, ["params", "cmd"]) ||
      Utils.map_path(payload, ["params", "argv"]) ||
      Utils.map_path(payload, ["params", "args"])
  end

  defp fallback_command(command, _payload), do: command

  defp normalize_command(%{} = command) do
    binary_command = Utils.map_value(command, ["parsedCmd", :parsedCmd, "command", :command, "cmd", :cmd])
    args = Utils.map_value(command, ["args", :args, "argv", :argv])

    if is_binary(binary_command) and is_list(args) do
      normalize_command([binary_command | args])
    else
      normalize_command(binary_command || args)
    end
  end

  defp normalize_command(command) when is_binary(command), do: Utils.inline_text(command)

  defp normalize_command(command) when is_list(command) do
    if Enum.all?(command, &is_binary/1) do
      command
      |> Enum.join(" ")
      |> Utils.inline_text()
    else
      nil
    end
  end

  defp normalize_command(_command), do: nil
  defp humanize_item_type(nil), do: "item"

  defp humanize_item_type(type) when is_binary(type) do
    type
    |> String.replace(~r/([a-z0-9])([A-Z])/, "\\1 \\2")
    |> String.replace("_", " ")
    |> String.replace("/", " ")
    |> String.downcase()
    |> String.trim()
  end

  defp humanize_item_type(type), do: to_string(type)

  defp humanize_status(status) when is_binary(status) do
    status
    |> String.replace("_", " ")
    |> String.replace("-", " ")
    |> String.downcase()
    |> String.trim()
  end

  defp humanize_status(_status), do: nil
  defp short_id(id) when is_binary(id) and byte_size(id) > 12, do: String.slice(id, 0, 12)
  defp short_id(id) when is_binary(id), do: id
  defp short_id(_id), do: nil
  defp append_if_present(list, value) when is_binary(value) and value != "", do: list ++ [value]
  defp append_if_present(list, _value), do: list

  defp wrapper_payload_type(payload) do
    Utils.map_path(payload, ["params", "msg", "payload", "type"]) ||
      Utils.map_path(payload, [:params, :msg, :payload, :type])
  end

  defp format_count(nil), do: "0"

  defp format_count(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> group_thousands()
  end

  defp format_count(value) when is_binary(value) do
    value
    |> String.trim()
    |> Integer.parse()
    |> case do
      {number, ""} -> group_thousands(Integer.to_string(number))
      _ -> value
    end
  end

  defp format_count(value), do: to_string(value)

  defp group_thousands(value) when is_binary(value) do
    sign = if String.starts_with?(value, "-"), do: "-", else: ""
    unsigned = if sign == "", do: value, else: String.slice(value, 1, String.length(value) - 1)

    unsigned
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
    |> prepend(sign)
  end

  defp prepend("", value), do: value
  defp prepend(prefix, value), do: prefix <> value
end
