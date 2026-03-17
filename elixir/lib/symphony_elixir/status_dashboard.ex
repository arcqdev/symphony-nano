defmodule SymphonyElixir.StatusDashboard do
  @moduledoc """
  Renders a status snapshot for orchestrator and worker activity as a terminal UI.
  """

  use GenServer
  require Logger

  alias SymphonyElixir.Config
  alias SymphonyElixir.Orchestrator
  alias SymphonyElixir.StatusDashboard.{CodexMessage, Renderer, Throughput}
  alias SymphonyElixirWeb.ObservabilityPubSub

  @minimum_idle_rerender_ms 1_000

  defstruct [
    :refresh_ms,
    :enabled,
    :render_interval_ms,
    :refresh_ms_override,
    :enabled_override,
    :render_interval_ms_override,
    :render_fun,
    :token_samples,
    :last_tps_second,
    :last_tps_value,
    :last_rendered_content,
    :last_rendered_at_ms,
    :pending_content,
    :flush_timer_ref,
    :last_snapshot_fingerprint
  ]

  @type t :: %__MODULE__{
          refresh_ms: pos_integer(),
          enabled: boolean(),
          render_interval_ms: pos_integer(),
          refresh_ms_override: pos_integer() | nil,
          enabled_override: boolean() | nil,
          render_interval_ms_override: pos_integer() | nil,
          render_fun: (String.t() -> term()),
          token_samples: [{integer(), integer()}],
          last_tps_second: integer() | nil,
          last_tps_value: float() | nil,
          last_rendered_content: String.t() | nil,
          last_rendered_at_ms: integer() | nil,
          pending_content: String.t() | nil,
          flush_timer_ref: reference() | nil,
          last_snapshot_fingerprint: term() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @spec notify_update(GenServer.name()) :: :ok
  def notify_update(server \\ __MODULE__) do
    ObservabilityPubSub.broadcast_update()

    case GenServer.whereis(server) do
      pid when is_pid(pid) ->
        send(pid, :refresh)
        :ok

      _ ->
        :ok
    end
  end

  @spec init(keyword()) :: {:ok, t()}
  def init(opts) do
    refresh_ms_override = keyword_override(opts, :refresh_ms)
    enabled_override = keyword_override(opts, :enabled)
    render_interval_ms_override = keyword_override(opts, :render_interval_ms)
    observability = Config.settings!().observability
    refresh_ms = refresh_ms_override || observability.refresh_ms
    render_interval_ms = render_interval_ms_override || observability.render_interval_ms
    render_fun = Keyword.get(opts, :render_fun, &render_to_terminal/1)
    enabled = resolve_override(enabled_override, observability.dashboard_enabled and dashboard_enabled?())
    schedule_tick(refresh_ms, enabled)

    {:ok,
     %__MODULE__{
       refresh_ms: refresh_ms,
       enabled: enabled,
       render_interval_ms: render_interval_ms,
       refresh_ms_override: refresh_ms_override,
       enabled_override: enabled_override,
       render_interval_ms_override: render_interval_ms_override,
       render_fun: render_fun,
       token_samples: [],
       last_tps_second: nil,
       last_tps_value: nil,
       last_rendered_content: nil,
       last_rendered_at_ms: nil,
       pending_content: nil,
       flush_timer_ref: nil,
       last_snapshot_fingerprint: nil
     }}
  end

  @spec render_offline_status() :: :ok
  def render_offline_status do
    Renderer.offline_content()
    |> render_to_terminal()

    :ok
  rescue
    error in [ArgumentError, RuntimeError] ->
      Logger.warning("Failed rendering offline status: #{Exception.message(error)}")
      :ok
  end

  @spec handle_info(term(), t()) :: {:noreply, t()}
  def handle_info(:tick, %{enabled: true} = state) do
    state = refresh_runtime_config(state)
    state = maybe_render(state)
    schedule_tick(state.refresh_ms, true)
    {:noreply, state}
  end

  def handle_info(:refresh, %{enabled: true} = state) do
    {:noreply, maybe_render(refresh_runtime_config(state))}
  end

  def handle_info(:refresh, state), do: {:noreply, state}

  def handle_info({:flush_render, timer_ref}, %{enabled: true, flush_timer_ref: timer_ref} = state) do
    now_ms = System.monotonic_time(:millisecond)

    state =
      case state.pending_content do
        nil ->
          %{state | flush_timer_ref: nil}

        content ->
          state
          |> Map.put(:flush_timer_ref, nil)
          |> Map.put(:pending_content, nil)
          |> render_content(content, now_ms)
      end

    {:noreply, state}
  end

  def handle_info({:flush_render, _timer_ref}, state), do: {:noreply, state}
  def handle_info(:tick, state), do: {:noreply, state}

  @doc false
  @spec rolling_tps([{integer(), integer()}], integer(), integer()) :: float()
  def rolling_tps(samples, now_ms, current_tokens),
    do: Throughput.rolling_tps(samples, now_ms, current_tokens)

  @doc false
  @spec throttled_tps(integer() | nil, float() | nil, integer(), [{integer(), integer()}], integer()) ::
          {integer(), float()}
  def throttled_tps(last_second, last_value, now_ms, token_samples, current_tokens),
    do: Throughput.throttled_tps(last_second, last_value, now_ms, token_samples, current_tokens)

  @doc false
  @spec format_timestamp_for_test(DateTime.t()) :: String.t()
  def format_timestamp_for_test(%DateTime{} = datetime), do: Renderer.format_timestamp(datetime)

  @doc false
  @spec format_snapshot_content_for_test(term(), number()) :: String.t()
  def format_snapshot_content_for_test(snapshot_data, tps),
    do: Renderer.format_snapshot_content(snapshot_data, tps)

  @doc false
  @spec format_snapshot_content_for_test(term(), number(), integer() | nil) :: String.t()
  def format_snapshot_content_for_test(snapshot_data, tps, terminal_columns),
    do: Renderer.format_snapshot_content(snapshot_data, tps, terminal_columns)

  @doc false
  @spec dashboard_url_for_test(String.t(), non_neg_integer() | nil, non_neg_integer() | nil) ::
          String.t() | nil
  def dashboard_url_for_test(host, configured_port, bound_port),
    do: Renderer.dashboard_url(host, configured_port, bound_port)

  @doc false
  @spec format_running_summary_for_test(map(), integer() | nil) :: String.t()
  def format_running_summary_for_test(running_entry, terminal_columns \\ nil),
    do: Renderer.format_running_summary(running_entry, terminal_columns)

  @doc false
  @spec format_tps_for_test(number()) :: String.t()
  def format_tps_for_test(value), do: Renderer.format_tps(value)

  @doc false
  @spec tps_graph_for_test([{integer(), integer()}], integer(), integer()) :: String.t()
  def tps_graph_for_test(samples, now_ms, current_tokens),
    do: Throughput.tps_graph(samples, now_ms, current_tokens)

  @doc false
  @spec humanize_codex_message(term()) :: String.t()
  def humanize_codex_message(message), do: CodexMessage.humanize_codex_message(message)

  defp refresh_runtime_config(%__MODULE__{} = state) do
    observability = Config.settings!().observability

    %{
      state
      | enabled: resolve_override(state.enabled_override, observability.dashboard_enabled and dashboard_enabled?()),
        refresh_ms: state.refresh_ms_override || observability.refresh_ms,
        render_interval_ms: state.render_interval_ms_override || observability.render_interval_ms
    }
  end

  defp schedule_tick(refresh_ms, true), do: Process.send_after(self(), :tick, refresh_ms)
  defp schedule_tick(_refresh_ms, false), do: :ok

  defp maybe_render(state) do
    now_ms = System.monotonic_time(:millisecond)
    {snapshot_data, token_samples} = snapshot_with_samples(state.token_samples, now_ms)
    state = Map.put(state, :token_samples, token_samples)
    current_tokens = Throughput.snapshot_total_tokens(snapshot_data)

    {tps_second, tps} =
      Throughput.throttled_tps(
        state.last_tps_second,
        state.last_tps_value,
        now_ms,
        token_samples,
        current_tokens
      )

    state =
      state
      |> Map.put(:last_tps_second, tps_second)
      |> Map.put(:last_tps_value, tps)

    if snapshot_data != state.last_snapshot_fingerprint or periodic_rerender_due?(state, now_ms) do
      content = Renderer.format_snapshot_content(snapshot_data, tps)

      state
      |> maybe_update_snapshot_fingerprint(snapshot_data)
      |> maybe_enqueue_render(content, now_ms)
    else
      state
    end
  rescue
    error in [ArgumentError, RuntimeError] ->
      Logger.warning("Failed rendering status dashboard: #{Exception.message(error)}")
      state
  end

  defp maybe_enqueue_render(state, content, now_ms) do
    cond do
      content == state.last_rendered_content ->
        state

      render_now?(state, now_ms) ->
        render_content(state, content, now_ms)

      true ->
        schedule_flush_render(%{state | pending_content: content}, now_ms)
    end
  end

  defp maybe_update_snapshot_fingerprint(state, snapshot_data) do
    if snapshot_data == state.last_snapshot_fingerprint do
      state
    else
      Map.put(state, :last_snapshot_fingerprint, snapshot_data)
    end
  end

  defp periodic_rerender_due?(%{last_rendered_at_ms: nil}, _now_ms), do: true

  defp periodic_rerender_due?(%{last_rendered_at_ms: last_rendered_at_ms}, now_ms)
       when is_integer(last_rendered_at_ms) do
    now_ms - last_rendered_at_ms >= @minimum_idle_rerender_ms
  end

  defp periodic_rerender_due?(_state, _now_ms), do: false
  defp render_now?(%{last_rendered_at_ms: nil, flush_timer_ref: nil}, _now_ms), do: true

  defp render_now?(%{last_rendered_at_ms: last_rendered_at_ms, render_interval_ms: render_interval_ms}, now_ms)
       when is_integer(last_rendered_at_ms) and is_integer(render_interval_ms) do
    now_ms - last_rendered_at_ms >= render_interval_ms
  end

  defp render_now?(_state, _now_ms), do: false

  defp schedule_flush_render(%{flush_timer_ref: timer_ref} = state, _now_ms) when is_reference(timer_ref),
    do: state

  defp schedule_flush_render(state, now_ms) do
    delay_ms = flush_delay_ms(state, now_ms)
    timer_ref = make_ref()
    Process.send_after(self(), {:flush_render, timer_ref}, delay_ms)
    %{state | flush_timer_ref: timer_ref}
  end

  defp flush_delay_ms(%{last_rendered_at_ms: nil}, _now_ms), do: 1

  defp flush_delay_ms(
         %{last_rendered_at_ms: last_rendered_at_ms, render_interval_ms: render_interval_ms},
         now_ms
       ) do
    remaining = render_interval_ms - (now_ms - last_rendered_at_ms)
    max(1, remaining)
  end

  defp render_content(state, content, now_ms) do
    state.render_fun.(content)

    %{
      state
      | last_rendered_content: content,
        last_rendered_at_ms: now_ms,
        pending_content: nil,
        flush_timer_ref: nil
    }
  rescue
    error in [ArgumentError, RuntimeError] ->
      Logger.warning("Failed rendering terminal dashboard frame: #{Exception.message(error)}")
      %{state | pending_content: nil, flush_timer_ref: nil}
  end

  defp snapshot_with_samples(token_samples, now_ms) do
    case snapshot_payload() do
      {:ok, %{running: running, retrying: retrying, codex_totals: codex_totals} = snapshot} ->
        total_tokens = Map.get(codex_totals, :total_tokens, 0)

        {
          {:ok,
           %{
             running: running,
             retrying: retrying,
             codex_totals: codex_totals,
             rate_limits: Map.get(snapshot, :rate_limits),
             polling: Map.get(snapshot, :polling)
           }},
          Throughput.update_token_samples(token_samples, now_ms, total_tokens)
        }

      :error ->
        {:error, Throughput.prune_samples(token_samples, now_ms)}
    end
  end

  defp snapshot_payload do
    if Process.whereis(Orchestrator) do
      case Orchestrator.snapshot() do
        %{running: running, retrying: retrying, codex_totals: codex_totals} = snapshot
        when is_list(running) and is_list(retrying) ->
          {:ok,
           %{
             running: running,
             retrying: retrying,
             codex_totals: codex_totals,
             rate_limits: Map.get(snapshot, :rate_limits),
             polling: Map.get(snapshot, :polling)
           }}

        _ ->
          :error
      end
    else
      :error
    end
  end

  defp render_to_terminal(content) do
    IO.write([
      IO.ANSI.home(),
      IO.ANSI.clear(),
      normalize_status_lines(content),
      "\n"
    ])
  end

  defp normalize_status_lines(content), do: content

  defp dashboard_enabled? do
    if Code.ensure_loaded?(Mix) and function_exported?(Mix, :env, 0) do
      try do
        Mix.env() != :test
      rescue
        _ -> true
      end
    else
      true
    end
  end

  defp keyword_override(opts, key) do
    if Keyword.has_key?(opts, key), do: Keyword.fetch!(opts, key), else: nil
  end

  defp resolve_override(nil, default), do: default
  defp resolve_override(override, _default), do: override
end
