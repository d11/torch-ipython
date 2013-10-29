require 'libluazmq'
require 'socket'
require 'json'

ipython = {}

dofile('session.lua')
dofile('completer.lua')

--! A file like object that publishes the stream to a 0MQ PUB socket.
local OutStream = torch.class("ipython.OutStream")

function OutStream:__init(session, pub_socket, name, max_buffer)
    max_buffer = max_buffer or 200
    self.session = session
    self.pub_socket = pub_socket
    self.name = name
    self._buffer = {}
    self._buffer_len = 0
    self.max_buffer = max_buffer
    self.parent_header = {}
end

function OutStream:set_parent(parent)
    self.parent_header = extract_header(parent)
end

function OutStream:close()
    self.pub_socket = nil
end

function OutStream:flush()
    if not self.pub_socket then
        error("I/O operation on closed file")
    else
        if self._buffer then
            local data = table.concat(self._buffer)
            local content = { name = self.name, data = data }
            local msg = self.session:msg('stream', content, self.parent_header)
            print(ipython.Message(msg))
            self.pub_socket:send(json.encode(msg))
            self._buffer_len = 0
            self._buffer = {}
        end
    end
end

function OutStream:isattr()
    return false
end
function OutStream:next()
    error("Read not supported on a write-only stream")
end
function OutStream:read()
    error("Read not supported on a write-only stream")
end
OutStream.readline = OutStream.read
function OutStream:write(s)
    if not self.pub_socket then
        error("I/O operation on closed file")
    else
        self._buffer[#self._buffer+1] = s
        self._buffer_len = self._buffer_len + string.len(s)
        self:_maybe_send()
    end
end

function OutStream:_maybe_send()
    if string.find(self._buffer[#self._buffer], "\n") then
        self:flush()
    end
    if self._buffer_len > self.max_buffer then
        self:flush()
    end
end

function OutStream:writelines(sequence)
    if not self.pub_socket then
        error("I/O operation on closed file")
    else
        for _, s in ipairs(sequence) do
            self:write(s)
        end
    end
end

local DisplayHook = torch.class("ipython.DisplayHook")

function DisplayHook:__init(session, pub_socket)
    self.session = session
    self.pub_socket = pub_socket
    self.parent_header = {}
end
function DisplayHook:__call(obj)
    if obj == nil then
        return
    end

    -- __builtin__._ = obj -- ?
    local msg = self.session:msg("pytout", { data = tostring(obj) }, self.parent_header)
    self.pub_socket:send(json.encode(msg))
end
function DisplayHook:set_parent(parent)
    self.parent_header = extract_header(parent)
end


local RawInput = torch.class("ipython.RawInput")
function RawInput:__init(session, socket)
    self.session = session
    self.socket = socket
end

function RawInput:__call(prompt)
    local msg = self.session:msg('raw_input')
    self.socket:send(json.encode(msg))
    while true do
        local result, msg = json.decode(self.socket:recv(zmq.NOBLOCK))
        if result then
            return msg.content.data
        end
        if msg ~= 'timeout' then
            error(msg)
        end
    end
end

local Kernel = torch.class("ipython.Kernel")
function Kernel:__init(session, reply_socket, pub_socket, stdout, stderr)
    self.stdout = stdout
    self.stderr = stderr
    self.session = session
    self.reply_socket = reply_socket
    self.pub_socket = pub_socket
    self.user_ns = {}
    self.history = {}
--    self.compiler = CommandCompiler()
    self.completer = ipython.KernelCompleter(self.user_ns)

    -- Build dict of handlers for message types
    self.handlers = {}
    for _, msg_type in ipairs({'execute_request', 'complete_request'}) do
        self.handlers[msg_type] = Kernel[msg_type]
    end
end

function Kernel:abort_queue()
    local ident, msg
    while true do
        local result
        result, ident = self.reply_socket:recv(zmq.NOBLOCK)
        if not result then
            if ident == 'timeout' then
                break
            end
        end
        if self.reply_socket.rcvmore ~= 0 then
            error("Unexpected missing message part")
        end
        msg = json.decode(self.reply_socket:recv())
        print("Aborting:", ipython.Message(msg))
        local msg_type = msg.msg_type
        local reply_type = msg_type:gmatch("_")[1] .. "_reply"
        local reply_msg = self.session.msg(reply_type, { status = 'aborted'}, msg)
        print(ipython.Message(reply_msg))
        self.reply_socket:send(ident, zmq.SNDMORE)
        self.reply_socket:send(json.encode(reply_msg))
        socket.sleep(0.1)
    end
end

function Kernel:execute_request(ident, parent)
    if not parent.content or not parent.content.code then
        print("Got bad msg: ", ipython.Message(parent))
        return
    end
    local code = parent.content.code
    local pyin_msg = self.session:msg('pyin', {code=code}, parent)
    self.pub_socket:send(json.encode(pyin_msg))
--    local comp_code = self.compiler(code, '<zmq-kernel>')
    local comp_code = code
    -- TODO sys.displayhook.set_parent(parent)
    local func, msg = loadstring(comp_code)
    local result
    local returned = msg
    if func then
        setfenv(func, self.user_ns)
        result, returned = pcall(func)
    end
    local reply_content
    if not result then
        local res = 'error'
        local tb = debug.traceback()
        local exc_content = {
            status = 'error',
            traceback = 'tb',
            etype = returned,
            evalue = returned
        }
        local exc_msg = self.session:msg('pyerr', exc_content, parent)
        self.pub_socket:send(json.encode(exc_msg))
        reply_content = exc_content
    else
        reply_content = {status = 'ok'}
    end
    local reply_msg = self.session:msg('execute_reply', reply_content, parent)
    print(ipython.Message(reply_msg))
--    self.reply_socket:send(ident, zmq.SNDMORE) -- TODO ?
    self.reply_socket:send(json.encode(reply_msg))
    if reply_msg.content.status == 'error' then
        self:abort_queue()
    end
end

function Kernel:complete_request(ident, parent)
    local matches = {
        matches = self.complete(parent),
        status = 'ok'
    }
    local completion_msg = self.session:send(self.reply_socket, 'complete_reply',
        matches, parent, ident)
    print(completion_msg)
end
function Kernel:complete(msg)
    return self.completer:complete(msg.content.line, msg.content.text)
end
function Kernel:start()
    print("starting....")
    while true do
        print("waiting on reply socket")
--        local ident = self.reply_socket:recv()
--        print("recieved ident " .. ident)
--        assert(self.reply_socket.rcvmore ~= 0, "Unexpected missing message part")
        local msg = json.decode(self.reply_socket:recv())
        print("recieved msg ", msg)
        local omsg = ipython.Message(msg)
        print(omsg)
        local handler = self.handlers[omsg.msg_type]
        if not handler then
            print("UNKNOWN MESSAGE TYPE: " .. omsg)
        else
            handler(self, ident, omsg)
        end
    end
end

function main()
    local c = zmq.init(1)
    local ip = '127.0.0.1'
    local port_base = 5555
    local connection = 'tcp://' .. ip .. ":"
    local rep_conn = connection .. port_base
    local pub_conn = connection .. port_base + 1

    print("Starting the kernel...")
    print("On: " .. rep_conn .. " " .. pub_conn)

    local session = ipython.Session({username='kernel'})
    local reply_socket = c:socket(zmq.XREQ)
    reply_socket:bind(rep_conn)

    local pub_socket = c:socket(zmq.XREP)
    pub_socket:bind(pub_conn)

    local stdout = ipython.OutStream(session, pub_socket, 'stdout')
    local stderr = ipython.OutStream(session, pub_socket, 'stderr')
    local newprint = function(args)
        print("print", args)
        local msg = args
        if type(args) == 'table' then
            msg = table.concat(args)
        end
        stdout:write(tostring(msg).. "\n")
    end
    local display_hook = ipython.DisplayHook(session, pub_socket)
    -- sys.display_hook = display_hook

    local kernel = ipython.Kernel(session, reply_socket, pub_socket)
    kernel.user_ns['print'] = newprint
    kernel.user_ns['torch'] = torch
    kernel.user_ns['loadstring'] = loadstring
    kernel.user_ns['sleep'] = socket.sleep
    kernel.user_ns['s'] = "test string"

    print "Use Ctrl-\\ (NOT Ctrl-C!) to terminate."
    kernel:start()

end


main()
