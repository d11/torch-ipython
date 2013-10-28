require 'libluazmq'
local uuid = require 'uuid'

local Message = torch.class("ipython.Message")

function Message:__init(args)
    for k, v in pairs(args) do
        if type(v) == 'table' then
            self[k] = ipython.Message(v)
        else
            self[k] = v
        end
    end
end

function Message:dict()
    local d = {}
    for k, v in pairs(self) do
        d[k] = v
    end
    return d
end

function msg_header(msg_id, username, session)
    return {
        msg_id = msg_id,
        username = usename,
        session = session
    }
end

function extract_header(msg_or_header)
    if not msg_ord_header then
        return {}
    end

    local h = msg_or_header.header
    if not h then
        h = msg_or_header.msg_id
        if not h then
            error()
        end
        h = msg_or_header -- ?
    end
    if type(h) ~= 'table' then
        h = {h}
    end
    return h
end

local Session = torch.class("ipython.Session")

function Session:__init(args)
    args.username = args.username or os.getenv('USER')

    self.username = username
    self.session = uuid.new()
    self.msg_id = 0
end

function Session:msg_header()
    local h = msg_header(self.msg_id, self.username, self.session)
    self.msg_id = self.msg_id + 1
    return h
end

function Session:msg(msg_type, content, parent)
    local msg = {}
    msg.header = self:msg_header()
    msg.parent_header = parent and extract_header(parent) or {}
    msg.msg_type = msg_type
    msg.content = content or {}
    return msg
end

function Session:send(socket, msg_type, content, parent, ident)
    local msg = self:msg(msg_type, content, parent)
    if ident then
        socket:send(ident, zmq.SNDMORE)
    end
    socket:send_json(msg)
    local omsg = Message(msg)
    return omsg
end

function Session:recv(socket, mode)
    mode = mode or zmq.NOBLOCK
    local result, msg = pcall(socket:recv_json(mode))
    if result then
        return Message(msg)
    else
        if msg == 'timeout' then
            return nil
        else
            error(msg)
        end
    end
end

local tests = {}
local tester = torch.Tester()
function tests.test_msg2obj()
    local am = { x = 1 }
    local ao = ipython.Message(am)
    tester:asserteq(ao.x, am.x, 'x values do not match')

    am.y = { z = 1 }
    ao = ipython.Message(am)
    tester:asserteq(ao.y.z, am.y.z, 'y.z values do not match')

    local k1, k2 = 'y', 'z'
    tester:asserteq(ao[k1][k2], am[k1][k2], 'k1.k2 values do not match')

    local am2 = ao:dict()
    tester:asserteq(am.x, am2.x, 'am.x values do not match')
    tester:asserteq(am.y.z, am2.y.z, 'am.y.z values do not match')
end

function ipython.test()
    tester:add(tests)
    tester:run()
end
