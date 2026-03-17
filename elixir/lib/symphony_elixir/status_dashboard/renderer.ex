defmodule SymphonyElixir.StatusDashboard.Renderer do
  @moduledoc false

  alias SymphonyElixir.{Config, HttpServer}
  alias SymphonyElixir.StatusDashboard.CodexMessage

  @running_id_width 8
  @running_stage_width 14
  @running_pid_width 8
  @running_age_width 12
  @running_tokens_width 10
  @running_session_width 14
  @running_event_default_width 44
  @running_event_min_width 12
  @running_row_chrome_width 10
  @default_terminal_columns 115

  @ansi_reset IO.ANSI.reset()
  @ansi_bold IO.ANSI.bright()
  @ansi_blue IO.ANSI.blue()
  @ansi_cyan IO.ANSI.cyan()
  @ansi_dim IO.ANSI.faint()
  @ansi_green IO.ANSI.green()
  @ansi_red IO.ANSI.red()
  @ansi_orange IO.ANSI.yellow()
  @ansi_yellow IO.ANSI.yellow()
  @ansi_magenta IO.ANSI.magenta()
  @ansi_gray IO.ANSI.light_black()

  @doc false
  @spec offline_content() :: String.t()
  def offline_content do
    [
      colorize("╭─ SYMPHONY STATUS", @ansi_bold),
      colorize("│ app_status=offline", @ansi_red),
      closing_border()
    ]
    |> Enum.join("\n")
  end

  @doc false
  @spec format_snapshot_content(term(), number(), integer() | nil) :: String.t()
  def format_snapshot_content(snapshot_data, tps, terminal_columns_override \\ nil) do
    case snapshot_data do
      {:ok, %{running: running, retrying: retrying, codex_totals: codex_totals} = snapshot} ->
        rate_limits = Map.get(snapshot, :rate_limits)
        project_link_lines = format_project_link_lines()
        project_refresh_line = format_project_refresh_line(Map.get(snapshot, :polling))
        codex_input_tokens = Map.get(codex_totals, :input_tokens, 0)
        codex_output_tokens = Map.get(codex_totals, :output_tokens, 0)
        codex_total_tokens = Map.get(codex_totals, :total_tokens, 0)
        codex_seconds_running = Map.get(codex_totals, :seconds_running, 0)
        agent_count = length(running)
        max_agents = Config.settings!().agent.max_concurrent_agents
        running_event_width = running_event_width(terminal_columns_override)
        running_rows = format_running_rows(running, running_event_width)
        running_to_backoff_spacer = if(running == [], do: [], else: ["│"])
        backoff_rows = format_retry_rows(retrying)

        ([
           colorize("╭─ SYMPHONY STATUS", @ansi_bold),
           colorize("│ Agents: ", @ansi_bold) <>
             colorize("#{agent_count}", @ansi_green) <>
             colorize("/", @ansi_gray) <>
             colorize("#{max_agents}", @ansi_gray),
           colorize("│ Throughput: ", @ansi_bold) <> colorize("#{format_tps(tps)} tps", @ansi_cyan),
           colorize("│ Runtime: ", @ansi_bold) <>
             colorize(format_runtime_seconds(codex_seconds_running), @ansi_magenta),
           colorize("│ Tokens: ", @ansi_bold) <>
             colorize("in #{format_count(codex_input_tokens)}", @ansi_yellow) <>
             colorize(" | ", @ansi_gray) <>
             colorize("out #{format_count(codex_output_tokens)}", @ansi_yellow) <>
             colorize(" | ", @ansi_gray) <>
             colorize("total #{format_count(codex_total_tokens)}", @ansi_yellow),
           colorize("│ Rate Limits: ", @ansi_bold) <> format_rate_limits(rate_limits),
           project_link_lines,
           project_refresh_line,
           colorize("├─ Running", @ansi_bold),
           "│",
           running_table_header_row(running_event_width),
           running_table_separator_row(running_event_width)
         ] ++
           running_rows ++
           running_to_backoff_spacer ++
           [colorize("├─ Backoff queue", @ansi_bold), "│"] ++
           backoff_rows ++
           [closing_border()])
        |> List.flatten()
        |> Enum.join("\n")

      :error ->
        [
          colorize("╭─ SYMPHONY STATUS", @ansi_bold),
          colorize("│ Orchestrator snapshot unavailable", @ansi_red),
          colorize("│ Throughput: ", @ansi_bold) <> colorize("#{format_tps(tps)} tps", @ansi_cyan),
          format_project_link_lines(),
          format_project_refresh_line(nil),
          closing_border()
        ]
        |> List.flatten()
        |> Enum.join("\n")
    end
  end

  @doc false
  @spec dashboard_url(String.t(), non_neg_integer() | nil, non_neg_integer() | nil) ::
          String.t() | nil
  def dashboard_url(_host, nil, _bound_port), do: nil

  def dashboard_url(host, configured_port, bound_port) do
    port = bound_port || configured_port

    if is_integer(port) and port > 0 do
      "http://#{dashboard_url_host(host)}:#{port}/"
    else
      nil
    end
  end

  @doc false
  @spec format_running_summary(map(), integer() | nil) :: String.t()
  def format_running_summary(running_entry, terminal_columns \\ nil) do
    do_format_running_summary(running_entry, running_event_width(terminal_columns))
  end

  @doc false
  @spec format_tps(number()) :: String.t()
  def format_tps(value) when is_number(value) do
    value
    |> trunc()
    |> Integer.to_string()
    |> group_thousands()
  end

  @doc false
  @spec format_timestamp(DateTime.t()) :: String.t()
  def format_timestamp(datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_string()
  end

  defp format_project_link_lines do
    project_part =
      case Config.settings!().tracker.project_slug do
        project_slug when is_binary(project_slug) and project_slug != "" ->
          colorize(linear_project_url(project_slug), @ansi_cyan)

        _ ->
          colorize("n/a", @ansi_gray)
      end

    project_line = colorize("│ Project: ", @ansi_bold) <> project_part

    case dashboard_url() do
      url when is_binary(url) ->
        [project_line, colorize("│ Dashboard: ", @ansi_bold) <> colorize(url, @ansi_cyan)]

      _ ->
        [project_line]
    end
  end

  defp format_project_refresh_line(%{checking?: true}) do
    colorize("│ Next refresh: ", @ansi_bold) <> colorize("checking now…", @ansi_cyan)
  end

  defp format_project_refresh_line(%{next_poll_in_ms: due_in_ms}) when is_integer(due_in_ms) do
    due_in_ms = max(due_in_ms, 0)
    seconds = div(due_in_ms + 999, 1000)
    colorize("│ Next refresh: ", @ansi_bold) <> colorize("#{seconds}s", @ansi_cyan)
  end

  defp format_project_refresh_line(_) do
    colorize("│ Next refresh: ", @ansi_bold) <> colorize("n/a", @ansi_gray)
  end

  defp linear_project_url(project_slug), do: "https://linear.app/project/#{project_slug}/issues"

  defp dashboard_url do
    dashboard_url(Config.settings!().server.host, Config.server_port(), HttpServer.bound_port())
  end

  defp dashboard_url_host(host) when host in ["0.0.0.0", "::", "[::]", ""], do: "127.0.0.1"

  defp dashboard_url_host(host) when is_binary(host) do
    trimmed_host = String.trim(host)

    cond do
      trimmed_host in ["0.0.0.0", "::", "[::]", ""] ->
        "127.0.0.1"

      String.starts_with?(trimmed_host, "[") and String.ends_with?(trimmed_host, "]") ->
        trimmed_host

      String.contains?(trimmed_host, ":") ->
        "[#{trimmed_host}]"

      true ->
        trimmed_host
    end
  end

  defp format_running_rows(running, running_event_width) do
    if running == [] do
      [
        "│  " <> colorize("No active agents", @ansi_gray),
        "│"
      ]
    else
      running
      |> Enum.sort_by(& &1.identifier)
      |> Enum.map(&do_format_running_summary(&1, running_event_width))
    end
  end

  # credo:disable-for-next-line
  defp do_format_running_summary(running_entry, running_event_width) do
    issue = format_cell(running_entry.identifier || "unknown", @running_id_width)
    state = running_entry.state || "unknown"
    state_display = format_cell(to_string(state), @running_stage_width)
    session = running_entry.session_id |> compact_session_id() |> format_cell(@running_session_width)
    pid = format_cell(running_entry.codex_app_server_pid || "n/a", @running_pid_width)
    total_tokens = running_entry.codex_total_tokens || 0
    runtime_seconds = running_entry.runtime_seconds || 0
    turn_count = Map.get(running_entry, :turn_count, 0)
    age = format_cell(format_runtime_and_turns(runtime_seconds, turn_count), @running_age_width)
    event = running_entry.last_codex_event || "none"
    event_label = format_cell(summarize_message(running_entry.last_codex_message), running_event_width)
    tokens = format_count(total_tokens) |> format_cell(@running_tokens_width, :right)

    status_color =
      case event do
        :none -> @ansi_red
        "codex/event/token_count" -> @ansi_yellow
        "codex/event/task_started" -> @ansi_green
        "turn_completed" -> @ansi_magenta
        _ -> @ansi_blue
      end

    [
      "│ ",
      status_dot(status_color),
      " ",
      colorize(issue, @ansi_cyan),
      " ",
      colorize(state_display, status_color),
      " ",
      colorize(pid, @ansi_yellow),
      " ",
      colorize(age, @ansi_magenta),
      " ",
      colorize(tokens, @ansi_yellow),
      " ",
      colorize(session, @ansi_cyan),
      " ",
      colorize(event_label, status_color)
    ]
    |> Enum.join("")
  end

  defp summarize_message(message), do: CodexMessage.humanize_codex_message(message)

  defp format_retry_rows(retrying) do
    if retrying == [] do
      ["│  " <> colorize("No queued retries", @ansi_gray)]
    else
      retrying
      |> Enum.sort_by(& &1.due_in_ms)
      |> Enum.map_join(", ", &format_retry_summary/1)
      |> String.split(", ")
    end
  end

  defp format_retry_summary(retry_entry) do
    issue_id = retry_entry.issue_id || "unknown"
    identifier = retry_entry.identifier || issue_id
    attempt = retry_entry.attempt || 0
    due_in_ms = retry_entry.due_in_ms || 0
    error = format_retry_error(retry_entry.error)

    "│  #{colorize("↻", @ansi_orange)} " <>
      colorize("#{identifier}", @ansi_red) <>
      " " <>
      colorize("attempt=#{attempt}", @ansi_yellow) <>
      colorize(" in ", @ansi_dim) <>
      colorize(next_in_words(due_in_ms), @ansi_cyan) <>
      error
  end

  defp next_in_words(due_in_ms) when is_integer(due_in_ms) do
    secs = div(due_in_ms, 1000)
    millis = rem(due_in_ms, 1000)
    "#{secs}.#{String.pad_leading(to_string(millis), 3, "0")}s"
  end

  defp next_in_words(_), do: "n/a"

  defp format_retry_error(error) when is_binary(error) do
    sanitized =
      error
      |> String.replace("\\r\\n", " ")
      |> String.replace("\\r", " ")
      |> String.replace("\\n", " ")
      |> String.replace("\r\n", " ")
      |> String.replace("\r", " ")
      |> String.replace("\n", " ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    if sanitized == "" do
      ""
    else
      " " <> colorize("error=#{truncate(sanitized, 96)}", @ansi_dim)
    end
  end

  defp format_retry_error(_), do: ""

  defp format_runtime_seconds(seconds) when is_integer(seconds) do
    mins = div(seconds, 60)
    secs = rem(seconds, 60)
    "#{mins}m #{secs}s"
  end

  defp format_runtime_seconds(seconds) when is_binary(seconds), do: seconds
  defp format_runtime_seconds(_), do: "0m 0s"

  defp format_runtime_and_turns(seconds, turn_count) when is_integer(turn_count) and turn_count > 0 do
    "#{format_runtime_seconds(seconds)} / #{turn_count}"
  end

  defp format_runtime_and_turns(seconds, _turn_count), do: format_runtime_seconds(seconds)
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

  defp running_table_header_row(running_event_width) do
    header =
      [
        format_cell("ID", @running_id_width),
        format_cell("STAGE", @running_stage_width),
        format_cell("PID", @running_pid_width),
        format_cell("AGE / TURN", @running_age_width),
        format_cell("TOKENS", @running_tokens_width),
        format_cell("SESSION", @running_session_width),
        format_cell("EVENT", running_event_width)
      ]
      |> Enum.join(" ")

    "│   " <> colorize(header, @ansi_gray)
  end

  defp running_table_separator_row(running_event_width) do
    separator_width =
      @running_id_width +
        @running_stage_width +
        @running_pid_width +
        @running_age_width +
        @running_tokens_width +
        @running_session_width +
        running_event_width + 6

    "│   " <> colorize(String.duplicate("─", separator_width), @ansi_gray)
  end

  defp running_event_width(terminal_columns) do
    terminal_columns = terminal_columns || terminal_columns()
    max(@running_event_min_width, terminal_columns - fixed_running_width() - @running_row_chrome_width)
  end

  defp fixed_running_width do
    @running_id_width +
      @running_stage_width +
      @running_pid_width +
      @running_age_width +
      @running_tokens_width +
      @running_session_width
  end

  defp terminal_columns do
    case :io.columns() do
      {:ok, columns} when is_integer(columns) and columns > 0 -> columns
      _ -> terminal_columns_from_env()
    end
  end

  defp terminal_columns_from_env do
    case System.get_env("COLUMNS") do
      nil ->
        fixed_running_width() + @running_row_chrome_width + @running_event_default_width

      value ->
        case Integer.parse(String.trim(value)) do
          {columns, ""} when columns > 0 -> columns
          _ -> @default_terminal_columns
        end
    end
  end

  defp format_cell(value, width, align \\ :left) do
    value =
      value
      |> to_string()
      |> String.replace("\n", " ")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> truncate_plain(width)

    case align do
      :right -> String.pad_leading(value, width)
      _ -> String.pad_trailing(value, width)
    end
  end

  defp truncate_plain(value, width) do
    if byte_size(value) <= width do
      value
    else
      String.slice(value, 0, width - 3) <> "..."
    end
  end

  defp compact_session_id(nil), do: "n/a"
  defp compact_session_id(session_id) when not is_binary(session_id), do: "n/a"

  defp compact_session_id(session_id) do
    if String.length(session_id) > 10 do
      String.slice(session_id, 0, 4) <> "..." <> String.slice(session_id, -6, 6)
    else
      session_id
    end
  end

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
  defp status_dot(color_code), do: colorize("●", color_code)
  defp format_rate_limits(nil), do: colorize("unavailable", @ansi_gray)

  defp format_rate_limits(rate_limits) when is_map(rate_limits) do
    limit_id = map_value(rate_limits, ["limit_id", :limit_id, "limit_name", :limit_name]) || "unknown"
    primary = format_rate_limit_bucket(map_value(rate_limits, ["primary", :primary]))
    secondary = format_rate_limit_bucket(map_value(rate_limits, ["secondary", :secondary]))
    credits = format_rate_limit_credits(map_value(rate_limits, ["credits", :credits]))

    colorize(to_string(limit_id), @ansi_yellow) <>
      colorize(" | ", @ansi_gray) <>
      colorize("primary #{primary}", @ansi_cyan) <>
      colorize(" | ", @ansi_gray) <>
      colorize("secondary #{secondary}", @ansi_cyan) <>
      colorize(" | ", @ansi_gray) <>
      colorize(credits, @ansi_green)
  end

  defp format_rate_limits(other) do
    other
    |> inspect(limit: 10)
    |> truncate(80)
    |> colorize(@ansi_gray)
  end

  defp format_rate_limit_bucket(nil), do: "n/a"

  defp format_rate_limit_bucket(bucket) when is_map(bucket) do
    remaining = map_value(bucket, ["remaining", :remaining])
    limit = map_value(bucket, ["limit", :limit])

    reset_value =
      map_value(bucket, [
        "reset_in_seconds",
        :reset_in_seconds,
        "resetInSeconds",
        :resetInSeconds,
        "reset_at",
        :reset_at,
        "resetAt",
        :resetAt,
        "resets_at",
        :resets_at,
        "resetsAt",
        :resetsAt
      ])

    base =
      cond do
        integer_like?(remaining) and integer_like?(limit) -> "#{format_count(remaining)}/#{format_count(limit)}"
        integer_like?(remaining) -> "remaining #{format_count(remaining)}"
        integer_like?(limit) -> "limit #{format_count(limit)}"
        map_size(bucket) == 0 -> "n/a"
        true -> bucket |> inspect(limit: 6) |> truncate(40)
      end

    if is_nil(reset_value), do: base, else: "#{base} reset #{format_reset_value(reset_value)}"
  end

  defp format_rate_limit_bucket(other), do: to_string(other)
  defp format_rate_limit_credits(nil), do: "credits n/a"

  defp format_rate_limit_credits(credits) when is_map(credits) do
    unlimited = map_value(credits, ["unlimited", :unlimited]) == true
    has_credits = map_value(credits, ["has_credits", :has_credits]) == true
    balance = map_value(credits, ["balance", :balance])

    cond do
      unlimited -> "credits unlimited"
      has_credits and is_number(balance) -> "credits #{format_number(balance)}"
      has_credits -> "credits available"
      true -> "credits none"
    end
  end

  defp format_rate_limit_credits(other), do: "credits #{to_string(other)}"
  defp format_reset_value(value) when is_integer(value), do: "#{format_count(value)}s"
  defp format_reset_value(value) when is_binary(value), do: value
  defp format_reset_value(value), do: to_string(value)
  defp format_number(value) when is_integer(value), do: format_count(value)

  defp format_number(value) when is_float(value) do
    value
    |> Float.round(2)
    |> :erlang.float_to_binary(decimals: 2)
  end

  defp map_value(map, keys) when is_map(map) and is_list(keys), do: Enum.find_value(keys, &Map.get(map, &1))
  defp map_value(_map, _keys), do: nil
  defp integer_like?(value) when is_integer(value), do: true
  defp integer_like?(_value), do: false
  defp closing_border, do: "╰─"
  defp colorize(value, code), do: "#{code}#{value}#{@ansi_reset}"

  defp truncate(value, max) when byte_size(value) > max do
    value |> String.slice(0, max) |> Kernel.<>("...")
  end

  defp truncate(value, _max), do: value
end
