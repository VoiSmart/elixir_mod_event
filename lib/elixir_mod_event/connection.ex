defmodule FSModEvent.Connection do
  @moduledoc """
  Connection process. A Connection that you can plug into your own supervisor
  tree.

  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket

  Copyright 2015 Marcelo Gornstein <marcelog@gmail.com>

  Licensed under the Apache License, Version 2.0 (the "License");
  you may not use this file except in compliance with the License.
  You may obtain a copy of the License at
      http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing, software
  distributed under the License is distributed on an "AS IS" BASIS,
  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
  See the License for the specific language governing permissions and
  limitations under the License.
  """
  alias FSModEvent.Packet, as: Packet
  use Connection
  require Logger
  defstruct name: nil,
    reconnect: nil,
    sync: false,
    host: nil,
    port: nil,
    password: nil,
    socket: nil,
    buffer: "",
    state: :disconnected,
    sender: nil,
    jobs: %{},
    max_attempts: nil,
    auto_connect: true,
    listeners: %{}

  @max_reconnection_delay 10

  @typep t :: %FSModEvent.Connection{}

  @doc """
  Registers the caller process as a receiver for all the events for which the
  filter_fun returns true.
  """
  @spec start_listening(Connection.server, fun) :: :ok
  def start_listening(name, filter_fun \\ fn(_) -> true end) do
    Connection.cast name, {:start_listening, self(), filter_fun}
  end

  @doc """
  Unregisters the caller process as a listener.
  """
  @spec stop_listening(Connection.server) :: :ok
  def stop_listening(name) do
    Connection.cast name, {:stop_listening, self()}
  end

  @doc """
  Starts a connection to FreeSWITCH.
  """
  @spec start(map()) :: Connection.on_start
  def start(conf) do
    Connection.start __MODULE__, conf
  end

  @spec start(atom, map()) :: Connection.on_start
  def start(name, conf) do
    Connection.start __MODULE__, conf, name: name
  end

  @doc """
  Starts and links a connection to FreeSWITCH.
  """
  @spec start_link(map()) :: Connection.on_start
  def start_link(conf) do
    Connection.start_link __MODULE__, conf
  end

  @spec start_link(atom, map()) :: Connection.on_start
  def start_link(name, conf) do
    Connection.start_link __MODULE__, conf, name: name
  end

  @doc """
  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-api

  For a list of available commands see: https://freeswitch.org/confluence/display/FREESWITCH/mod_commands
  """
  @spec api(Connection.server, String.t, String.t) :: FSModEvent.Packet.t
  def api(name, command, args \\ "") do
    block_send name, "api #{command} #{args}"
  end

  @doc """
  Executes an API command in background. Returns a Job ID. The calling process
  will receive a message like {:fs_job_result, job_id, packet} with the result.

  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-bgapi
  """
  @spec bgapi(Connection.server, String.t, String.t) :: String.t
  def bgapi(name, command, args \\ "") do
    Connection.call name, {:bgapi, self(), command, args}
  end

  @doc """
  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-linger
  """
  @spec linger(Connection.server) :: FSModEvent.Packet.t
  def linger(name) do
    block_send name, "linger"
  end

  @doc """
  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-nolinger
  """
  @spec nolinger(Connection.server) :: FSModEvent.Packet.t
  def nolinger(name) do
    block_send name, "nolinger"
  end

  @doc """
  This will always prepend your list with "plain" if not specified.

  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-event
  """
  @spec event(Connection.server, String.t, String.t) :: FSModEvent.Packet.t
  def event(name, events, format \\ "plain") do
    block_send name, "event #{format} #{events}"
  end

  @doc """
  This will always prepend your list with "plain" if not specified.

  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-SpecialCase-'myevents'
  """
  @spec myevents(Connection.server, String.t, String.t) :: FSModEvent.Packet.t
  def myevents(name, uuid, format \\ "plain") do
    block_send name, "myevents #{format} #{uuid}"
  end

  @doc """
  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-divert_events
  """
  @spec enable_divert_events(Connection.server) :: FSModEvent.Packet.t
  def enable_divert_events(name) do
    block_send name, "divert_events on"
  end

  @doc """
  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-divert_events
  """
  @spec disable_divert_events(Connection.server) :: FSModEvent.Packet.t
  def disable_divert_events(name) do
    block_send name, "divert_events off"
  end

  @doc """
  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-filter
  """
  @spec filter(Connection.server, String.t, String.t) :: FSModEvent.Packet.t
  def filter(name, key, value \\ "") do
    block_send name, "filter #{key} #{value}"
  end

  @doc """
  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-filterdelete
  """
  @spec filter_delete(
    Connection.server, String.t, String.t
  ) :: FSModEvent.Packet.t
  def filter_delete(name, key, value \\ "") do
    block_send name, "filter delete #{key} #{value}"
  end

  @doc """
  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-sendevent
  """
  @spec sendevent(
    Connection.server, String.t, [{String.t, String.t}], String.t
  ) :: FSModEvent.Packet.t
  def sendevent(name, event, headers \\ [], body \\ "") do
    length = String.length body
    headers = [{"content-length", to_string(length)}|headers]
    headers = for {k, v} <- headers, do: "#{k}: #{v}"
    lines = Enum.join ["sendevent #{event}"|headers], "\n"
    payload = if length === 0 do
      "#{lines}"
    else
      "#{lines}\n\n#{body}"
    end
    block_send name, payload
  end

  @doc """
  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-sendmsg
  """
  @spec sendmsg_exec(
    Connection.server, String.t, String.t, String.t, Integer.t, String.t
  ) :: FSModEvent.Packet.t
  def sendmsg_exec(name, uuid, command, args \\ "", loops \\ 1, body \\ "") do
    sendmsg name, uuid, "execute", [
      {"execute-app-name", command},
      {"execute-app-arg", args},
      {"loops", to_string(loops)}
    ], body
  end

  @doc """
  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-sendmsg
  """
  @spec sendmsg_hangup(
    Connection.server, String.t, Integer.t
  ) :: FSModEvent.Packet.t
  def sendmsg_hangup(name, uuid, cause \\ 16) do
    sendmsg name, uuid, "hangup", [{"hangup-cause", to_string(cause)}]
  end

  @doc """
  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-sendmsg
  """
  @spec sendmsg_unicast(
    Connection.server, String.t, String.t, String.t,
    String.t, Integer.t, String.t, Integer.t
  ) :: FSModEvent.Packet.t
  def sendmsg_unicast(
    name, uuid, transport \\ "tcp", flags \\ "native",
    local_ip \\ "127.0.0.1", local_port \\ 8025,
    remote_ip \\ "127.0.0.1", remote_port \\ 8026
  ) do
    sendmsg name, uuid, "unicast", [
      {"local-ip", local_ip},
      {"local-port", to_string(local_port)},
      {"remote-ip", remote_ip},
      {"remote-port", to_string(remote_port)},
      {"transport", transport},
      {"flags", flags}
    ]
  end

  @doc """
  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-sendmsg
  """
  @spec sendmsg_nomedia(
    Connection.server, String.t, String.t
  ) :: FSModEvent.Packet.t
  def sendmsg_nomedia(name, uuid, info \\ "") do
    sendmsg name, uuid, "nomedia", [{"nomedia-uuid", info}]
  end

  @doc """
  https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-exit
  """
  @spec exit(Connection.server) :: FSModEvent.Packet.t
  def exit(name) do
    block_send name, "exit"
  end

  @doc """
  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-log
  """
  @spec log(Connection.server, String.t) :: FSModEvent.Packet.t
  def log(name, level) do
    block_send name, "log #{level}"
  end

  @doc """
  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-nolog
  """
  @spec nolog(Connection.server) :: FSModEvent.Packet.t
  def nolog(name) do
    block_send name, "nolog"
  end

  @doc """
  Suppress the specified type of event.

  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-nixevent
  """
  @spec nixevent(Connection.server, String.t) :: FSModEvent.Packet.t
  def nixevent(name, events) do
    block_send name, "nixevent #{events}"
  end

  @doc """
  See: https://freeswitch.org/confluence/display/FREESWITCH/mod_event_socket#mod_event_socket-noevents
  """
  @spec noevents(Connection.server) :: FSModEvent.Packet.t
  def noevents(name) do
    block_send name, "noevents"
  end

  @spec init([term]) :: {:connect, :starting, FSModEvent.Connection.t} | no_return
  def init(conf) do
    conf_struct = struct(FSModEvent.Connection, conf)
    case conf_struct.auto_connect do
      true -> {:connect, :starting, conf_struct}
      false -> {:ok, conf_struct}
    end
  end

  def connect(:starting, state) do
    Logger.info "Starting FS connection"
    res = :gen_tcp.connect(
      to_char_list(state.host), state.port, [
        packet: 0, sndbuf: 4_194_304, recbuf: 4_194_304, active: :once, mode: :binary
      ]
    )

    case res do
      {:ok, socket} ->
        Logger.debug "Connected to FreeSWITCH: #{inspect socket}"
        {:ok, %FSModEvent.Connection{state | socket: socket, state: :connecting}}
      reason ->
        Logger.error "Cannot connect, reason: #{inspect reason}"
        do_reconnect(state, reason)
    end
  end

  def connect(:backoff, state = %FSModEvent.Connection{reconnect: :true}) do
    connect(:starting, %{state | state: :disconnected})
  end

  def connect(:backoff, state = %FSModEvent.Connection{reconnect: :false}) do
    {:stop, :normal, %{state | state: :disconnected}}
  end

  def connect(what, state) do
    raise "Unhandled connection info #{inspect what} with state #{inspect state}"
  end

  def disconnect(:disconnect, state = %FSModEvent.Connection{reconnect: :true}) do
    Logger.info "disconnected from FreeSWITCH, retrying..."
    Enum.each state.listeners, fn({_, v}) ->
      send v.pid, {:fs_event, :fs_down}
    end
    {:backoff, calculate_backoff(1), %{state | state: :disconnected}}
  end

  def disconnect(:disconnect, state = %FSModEvent.Connection{reconnect: :false}) do
    Logger.info "disconnected from FreeSWITCH, stopping."
    {:stop, :normal, %{state | state: :disconnected}}
  end

  def disconnect(what, state) do
    raise "Unhandled disconnection info #{inspect what} with state #{inspect state}"
  end

  @spec handle_call(
    term, term, FSModEvent.Connection.t
  ) :: {:noreply, FSModEvent.Connection.t} |
    {:reply, term, FSModEvent.Connection.t}
  def handle_call({:bgapi, caller, command, args}, _from, state) do
    id = UUID.uuid4
    cmd_send state.socket, "bgapi #{command} #{args}\nJob-UUID: #{id}"
    jobs = Map.put state.jobs, id, caller
    {:reply, id, %FSModEvent.Connection{state | jobs: jobs}}
  end

  def handle_call({:send, command}, from, state) do
    cmd_send state.socket, command
    {:noreply, %FSModEvent.Connection{state | sender: from}}
  end

  def handle_call(call, _from, state) do
    Logger.warn "Unknown call: #{inspect call}"
    {:reply, :unknown_call, state}
  end

  @spec handle_cast(
    term, FSModEvent.Connection.t
  ) :: {:noreply, FSModEvent.Connection.t}
  def handle_cast({:start_listening, caller, filter_fun}, state) do
    key = Base.encode64 :erlang.term_to_binary(caller)
    listeners = Map.put state.listeners, key, %{pid: caller, filter: filter_fun}
    Process.monitor caller
    {:noreply, %FSModEvent.Connection{state | listeners: listeners}}
  end

  def handle_cast({:stop_listening, caller}, state) do
    key = Base.encode64 :erlang.term_to_binary(caller)
    listeners = Map.delete state.listeners, key
    {:noreply, %FSModEvent.Connection{state | listeners: listeners}}
  end

  def handle_cast({:connect}, state) do
    {:connect, :starting, state}
  end

  def handle_cast(cast, state) do
    Logger.warn "Unknown cast: #{inspect cast}"
    {:noreply, state}
  end

  @spec handle_info(
    term, FSModEvent.Connection.t
  ) :: {:noreply, FSModEvent.Connection.t}
  def handle_info({:DOWN, _, _, pid, _}, state) do
    handle_cast {:stop_listening, pid}, state
  end

  def handle_info({:tcp, socket, data}, state) do
    :inet.setopts(socket, active: :once)
    buffer = state.buffer <> data
    {rest, ps} = Packet.parse buffer
    state = Enum.reduce ps, state, &process/2
    {:noreply, %FSModEvent.Connection{state | buffer: rest}}
  end

  def handle_info({:tcp_closed, _}, state) do
    Logger.info "Connection closed"
    {:disconnect, :disconnect, state}
  end

  def handle_info(message, state) do
    Logger.warn "Unknown message: #{inspect message}"
    {:noreply, state}
  end

  @spec terminate(term, FSModEvent.Connection.t) :: :ok
  def terminate(reason, _state) do
    Logger.info "Terminating with #{inspect reason}"
    :ok
  end

  @spec code_change(
    term, FSModEvent.Connection.t, term
  ) :: {:ok, FSModEvent.Connection.t}
  def code_change(_old_vsn, state, _extra) do
    {:ok,  state}
  end

  defp process(
    %Packet{type: "auth/request"},
    state = %FSModEvent.Connection{state: :connecting}
  ) do
    auth state.socket, state.password
    state
  end

  defp process(
    pkt = %Packet{type: "command/reply"},
    state = %FSModEvent.Connection{state: :connecting}
  ) do
    if pkt.success do
      Enum.each state.listeners, fn({_, v}) ->
        send v.pid, {:fs_event, :fs_up}
      end
      %FSModEvent.Connection{state | state: :connected}
    else
      raise "Could not login to FS: #{inspect pkt}"
    end
  end

  defp process(p, %FSModEvent.Connection{state: :connecting}) do
    raise "Unexpected packet while authenticating: #{inspect p}"
  end

  defp process(pkt, state) do
    new_state = cond do
      # Command immediate response
      Packet.is_response?(pkt) ->
        if not is_nil state.sender do
          Connection.reply state.sender, pkt
        end
        state
      # Regular event
      true ->
        # Background job response
        bg_state = is_background_job(state, pkt)
        # Notify listeners
        Enum.each state.listeners, fn({_, v}) ->
          if v.filter.(pkt) do
            send_listener v.pid, {:fs_event, pkt}, state
          end
        end
        bg_state
    end
    %FSModEvent.Connection{new_state | sender: nil}
  end

  defp auth(socket, password) do
    cmd_send socket, "auth #{password}"
  end

  defp sendmsg(name, uuid, command, headers, body \\ "") do
    length = String.length body
    headers = if length > 0 do
      [
        {"content-length", to_string(length)},
        {"content-type", "text/plain"}
        |headers
      ]
    else
      headers
    end
    headers = [{"call-command", command}|headers]
    headers = for {k, v} <- headers, do: "#{k}: #{v}"
    lines = Enum.join ["sendmsg #{uuid}"|headers], "\n"
    payload = if length === 0 do
      "#{lines}"
    else
      "#{lines}\n\n#{body}"
    end
    block_send name, payload
  end

  defp block_send(name, command) do
    Connection.call name, {:send, command}
  end

  defp cmd_send(socket, command) do
    c = "#{command}\n\n"
    Logger.debug "Sending #{c}"
    :ok = :gen_tcp.send socket, c
  end

  defp send_listener(pid, data, state) do
    case state.sync do
      :true -> GenServer.call pid, data
      _ -> send pid, data
    end
  end

  defp do_reconnect(state = %FSModEvent.Connection{reconnect: :true, max_attempts: nil}, _reason) do
    {:backoff, calculate_backoff(1), %{state | socket: nil, state: :disconnected}}
  end

  defp do_reconnect(state = %FSModEvent.Connection{reconnect: :true}, reason) do
    case state.max_attempts - 1 do
      attempts when attempts <= 0 ->
        {:stop, reason, %FSModEvent.Connection{state | socket: nil, state: :disconnected}}
      attempts ->
        backoff_time = calculate_backoff(attempts)
        {:backoff, backoff_time, %FSModEvent.Connection{state | socket: nil, state: :disconnected, max_attempts: attempts}}
    end
  end

  defp do_reconnect(state, reason) do
    {:stop, reason, %{state | socket: nil, state: :disconnected}}
  end

  defp calculate_backoff(attempt) do
    :backoff.rand_increment(attempt, @max_reconnection_delay) * 1000 # in ms
  end

  defp is_background_job(state, %FSModEvent.Packet{job_id: nil}) do
    state
  end
  defp is_background_job(state, pkt) do
    if not is_nil state.jobs[pkt.job_id] do
      send state.jobs[pkt.job_id], {:fs_job_result, pkt.job_id, pkt}
      new_jobs = Map.delete(state.jobs, pkt.job_id)
      %FSModEvent.Connection{state | jobs: new_jobs}
    else
      state
    end
  end

end
