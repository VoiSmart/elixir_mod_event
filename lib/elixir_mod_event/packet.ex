defmodule FSModEvent.Packet do
  @moduledoc """
  Parses FreeSWITCH packets.

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
  alias FSModEvent.Content, as: Content
  alias FSModEvent.Header, as: Header

  defstruct type: nil,
            success: false,
            headers_complete: false,
            payload_complete: false,
            complete: false,
            parse_error: false,
            headers: %{},
            length: 0,
            rest: nil,
            job_id: nil,
            custom_payload: nil,
            payload: nil

  @type t :: %FSModEvent.Packet{}

  @doc """
  true if the given packet is a response to an issued command.
  """
  @spec is_response?(FSModEvent.Packet.t()) :: boolean
  def is_response?(pkt) do
    pkt.type === "api/response" or pkt.type === "command/reply"
  end

  @doc """
  Parses all packets found in the given input buffer. Returns a tuple with the
  buffer leftovers and the packets parsed.
  """
  @spec parse(binary(), [FSModEvent.Packet.t()]) :: {binary(), [FSModEvent.Packet.t()]}
  def parse(char_list, acc \\ []) do
    pkt = parse_real(char_list)

    if pkt.parse_error or not pkt.complete do
      {char_list, Enum.reverse(acc)}
    else
      parse(pkt.rest, [%FSModEvent.Packet{pkt | rest: nil} | acc])
    end
  end

  defp parse_real(data) do
    %FSModEvent.Packet{
      rest: data
    }
    |> headers()
    |> payload()
    |> normalize()
  end

  defp headers(pkt = %FSModEvent.Packet{parse_error: false}) do
    case Header.parse(pkt.rest) do
      {key, value, rest} ->
        pkt = %FSModEvent.Packet{pkt | headers: Map.put(pkt.headers, key, value)}

        case rest do
          "\n" <> rest ->
            %FSModEvent.Packet{pkt | headers_complete: true, rest: rest}

          _ ->
            headers(%FSModEvent.Packet{pkt | rest: rest})
        end

      _error ->
        %FSModEvent.Packet{pkt | parse_error: true}
    end
  end

  defp payload(
         pkt = %FSModEvent.Packet{
           parse_error: false,
           headers: headers,
           rest: rest
         }
       ) do
    l =
      case headers["Content-Length"] do
        nil ->
          0

        l ->
          {l, ""} = Integer.parse(l)
          l
      end

    if byte_size(rest) >= l do
      p = :binary.part(rest, 0, l)
      lrest = byte_size(rest) - l

      rest =
        if lrest === 0 do
          ""
        else
          rstart =
            if l === 0 do
              0
            else
              l
            end

          :binary.part(rest, rstart, lrest)
        end

      if byte_size(p) === l do
        ctype = headers["Content-Type"]

        {p, custom_payload} =
          case Content.parse(ctype, p) do
            nil -> {"", ""}
            r -> r
          end

        %FSModEvent.Packet{
          pkt
          | payload_complete: true,
            length: l,
            payload: p,
            custom_payload: custom_payload,
            rest: rest
        }
      else
        %FSModEvent.Packet{pkt | parse_error: true}
      end
    else
      %FSModEvent.Packet{pkt | parse_error: true}
    end
  end

  defp payload(pkt), do: pkt

  defp normalize(pkt = %FSModEvent.Packet{parse_error: false}) do
    complete = pkt.headers_complete and pkt.payload_complete

    %FSModEvent.Packet{
      pkt
      | complete: complete,
        success: success?(pkt),
        job_id: extract_job_id(pkt),
        type: pkt.headers["Content-Type"]
    }
  end

  defp normalize(pkt), do: pkt

  defp extract_job_id(pkt) do
    case pkt.headers["Reply-Text"] do
      nil ->
        if is_map(pkt.payload) and not is_nil(pkt.payload["Job-UUID"]) do
          pkt.payload["Job-UUID"]
        else
          nil
        end

      job_id ->
        case Regex.run(~r/\+OK Job-UUID: (.*)$/, job_id) do
          nil -> nil
          [_, job_id] -> job_id
        end
    end
  end

  defp success?(pkt) do
    case pkt.headers["Reply-Text"] do
      nil -> false
      "+OK" <> _rest -> true
      _ -> false
    end
  end
end
