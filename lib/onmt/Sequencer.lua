require 'nngraph'

--[[ Sequencer is the base class for encoder and decoder models.
  Main task is to manage `self.network_clones`, the unrolled network
  used during training.
--]]
local Sequencer, parent = torch.class('onmt.Sequencer', 'nn.Module')

--[[ Constructor

Parameters:

  * `args` - global arguments
  * `network` - network to unroll.

--]]
function Sequencer:__init(args, network)
  parent.__init(self)

  self.args = args

  self.network = network
  self.network_clones = {}

  -- Prototype for preallocated hidden and cell states.
  self.stateProto = torch.Tensor()

  -- Prototype for preallocated output gradients.
  self.gradOutputProto = torch.Tensor()
end

function Sequencer:_sharedClone()
  local params, gradParams
  if self.network.parameters then
    params, gradParams = self.network:parameters()
    if params == nil then
      params = {}
    end
  end

  local mem = torch.MemoryFile("w"):binary()
  mem:writeObject(self.network)

  -- We need to use a new reader for each clone.
  -- We don't want to use the pointers to already read objects.
  local reader = torch.MemoryFile(mem:storage(), "r"):binary()
  local clone = reader:readObject()
  reader:close()

  if self.network.parameters then
    local cloneParams, cloneGradParams = clone:parameters()
    for i = 1, #params do
      cloneParams[i]:set(params[i])
      cloneGradParams[i]:set(gradParams[i])
    end
  end

  mem:close()

  return clone
end

--[[Get a clone for a timestep.

Parameters:
  * `t` - timestep.

Returns: The raw network clone at timestep t.
  When `evaluate()` has been called, cheat and return t=1.
]]
function Sequencer:net(t)
  if self.train then
    -- In train mode, the network has to be cloned to remember intermediate
    -- outputs for each timestep and to allow backpropagation through time.
    if self.network_clones[t] == nil then
      local clone = self:_sharedClone()
      clone:training()
      self.network_clones[t] = clone
    end
    return self.network_clones[t]
  else
    if #self.network_clones > 0 then
      return self.network_clones[1]
    else
      return self.network
    end
  end
end

--[[ Tell the network to prepare for training mode. ]]
function Sequencer:training()
  parent.training(self)

  if #self.network_clones > 0 then
    -- Only first clone can be used for evaluation.
    self.network_clones[1]:training()
  end
end

--[[ Tell the network to prepare for evaluation mode. ]]
function Sequencer:evaluate()
  parent.evaluate(self)

  if #self.network_clones > 0 then
    self.network_clones[1]:evaluate()
  else
    self.network:evaluate()
  end
end

return Sequencer
