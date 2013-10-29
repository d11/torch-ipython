
local KernelCompleter = torch.class("ipython.KernelCompleter")

function KernelCompleter:__init(namespace)
    self.namespace = namespace

end

function KernelCompleter:complete(line, text)
    local matches = {}
    -- TODO completion
    return matches
end
