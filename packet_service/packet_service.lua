local event = require('event')
local ffi = require('ffi')
local packet = require('packet')
local shared = require('shared')
local string = require('string')
local math = require('math')
local table = require('table')
local types = require('types')
local os = require('os')

packets_server = shared.new('packets')
types_server = shared.new('types')

types_server.data = types

local registry = {}
local history = {}

local amend_packet
amend_packet = function(packet, cdata, ftype)
    local count = ftype.count
    if count then
        local base = ftype.base
        if base.fields then
            for i = 0, count - 1 do
                packet[i] = amend_packet(packet[i] or {}, cdata[i], base)
            end
        else
            for i = 0, count - 1 do
                packet[i] = cdata[i]
            end
        end
    else
        for key, value in pairs(cdata) do
            if type(value) == 'cdata' then
                packet[key] = amend_packet(packet[key] or {}, value, ftype.fields[key].type)
            else
                packet[key] = value
            end
        end
    end

    return packet
end

local amend_cdata
amend_cdata = function(cdata, packet, ftype)
    local count = ftype.count
    if count then
        local base = ftype.base
        if base.fields then
            for i = 0, count - 1 do
                local value = packet[i]
                if value then
                    amend_cdata(cdata[i], value, base)
                end
            end
        else
            for i = 0, count - 1 do
                local value = packet[i]
                if value then
                    cdata[i] = value
                end
            end
        end

        return
    end

    for key, value in pairs(packet) do
        local value_ftype = ftype.fields[key].type
        if value_ftype.fields then
            amend_cdata(cdata[key], value, value_type)
        else
            cdata[key] = value
        end
    end
end

packets_server.env = {}

packets_server.env.get_last = function(path)
    return history[path]
end

do
    local event_new = event.new

    packets_server.env.make_event = function(path)
        local events = registry[path]
        if not events then
            events = {}
            registry[path] = events
        end

        local event = event_new()
        events[#events + 1] = event

        return event
    end
end

do
    local string_find = string.find
    local string_sub = string.sub
    local ffi_copy = ffi.copy
    local ffi_new = ffi.new
    local ffi_sizeof = ffi.sizeof
    local ffi_string = ffi.string
    local packet_new = packet.new
    local packet_inject_incoming = packet.inject_incoming
    local packet_inject_outgoing = packet.inject_outgoing
    local buffer_type = ffi.typeof('char[?]')

    local build_cdata
    build_cdata = function(ftype, values)
        local cdata
        local var_key = ftype.var_key
        local var_data = var_key and values[var_key]
        if var_data then
            if type(var_data) == 'string' then
                if ftype.converter == 'string' then
                    cdata = ffi_new(ftype.name, #var_data + 1)
                else
                    cdata = ffi_new(ftype.name, #var_data)
                end
            else
                local max_key = 0
                for key in pairs(var_data) do
                    if key > max_key then
                        max_key = key
                    end
                end
                cdata = ffi_new(ftype.name, max_key)
            end
        else
            cdata = ffi_new(ftype.name)
        end

        return cdata
    end

    local build_packet = function(path, values)
        local direction = string_sub(path, 2, 9)
        local next_slash_index = string_find(path, '/', 11)
        local id = tonumber(string_sub(path, 11, next_slash_index and next_slash_index - 1))

        local base_type = types[direction][id]
        local ftype
        local types = base_type.types
        if not types then
            ftype = base_type
        else
            if not next_slash_index then
                ftype = base_type.base
            else
                local key = string_sub(path, next_slash_index + 1)
                ftype = types[tonumber(key) or key] or base_type.base
            end
        end

        local cdata = build_cdata(ftype, values)

        amend_cdata(cdata, values, ftype)
        return cdata, ftype, direction, id
    end

    packets_server.env.inject = function(path, values)
        local cdata, _, direction, id = build_packet(path, values)

        local size = ffi_sizeof(cdata)
        local buffer = buffer_type(size)
        ffi_copy(buffer, cdata, size)

        local p = packet_new(id, ffi_string(buffer, size))
        if direction == 'incoming' then
            packet_inject_incoming(p)
        else
            packet_inject_outgoing(p)
        end
    end
end

local parse_packet
do
    local math_floor = math.floor
    local ffi_copy = ffi.copy
    local ffi_new = ffi.new

    local parse_single = function(data, ftype, packet)
        packet = packet or {}

        local size = #data
        local offset = ftype.size
        local single_var_size = ftype.var_size

        local cdata
        if single_var_size then
            local total_var_size = math_floor((size - offset) / single_var_size)
            offset = offset + total_var_size
            cdata = ffi_new(ftype.name, total_var_size)
        else
            cdata = ffi_new(ftype.name)
        end
        ffi_copy(cdata, data, offset)

        return amend_packet(packet, cdata, ftype)
    end

    parse_packet = function(data, ftype)
        if not ftype then
            return {}
        end

        if not ftype.types then
            return parse_single(data, ftype)
        end

        local base_packet = parse_single(data, ftype.base)

        local inner_ftype = ftype.types[base_packet[ftype.key]]
        if not inner_ftype then
            return base_packet
        end

        return parse_single(data, inner_ftype, base_packet)
    end
end

local process_packet = function(packet, path)
    local events = registry[path]
    if events then
        for i = 1, #events do
            events[i]:trigger(packet)
        end
    end

    history[path] = packet
end

local make_timestamp
do
    local os_time = os.time

    local last_time = os_time()
    local now_count = 0

    make_timestamp = function()
        local now = os_time()
        if last_time == now then
            now_count = now_count + 1
            return now + now_count / 10000
        end

        now_count = 0
        last_time = now
        return now
    end
end

local handle_packet =  function(direction, raw)
    local id = raw.id
    local data = raw.data

    local packet_info = {
        direction = direction,
        id = id,
        data = data,
        blocked = raw.blocked,
        modified = raw.modified,
        injected = raw.injected,
        timestamp = make_timestamp(),
    }

    local ftype = types[direction][id]
    local packet = parse_packet(data, ftype)
    packet._info = packet_info

    process_packet(packet, '')
    local path = '/' .. direction
    process_packet(packet, path)
    path = path .. '/' .. id
    process_packet(packet, path)

    local cache = ftype and ftype.info and ftype.info.cache
    if cache then
        for i = 1, #cache do
            path = path .. '/' .. tostring(packet[cache[i]])
            process_packet(packet, path)
        end
    end
end

packet.incoming:register(function(raw)
    handle_packet('incoming', raw)
end)

packet.outgoing:register(function(raw)
    handle_packet('outgoing', raw)
end)

--[[
Copyright © 2018, Windower Dev Team
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of the Windower Dev Team nor the
      names of its contributors may be used to endorse or promote products
      derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE WINDOWER DEV TEAM BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
]]
