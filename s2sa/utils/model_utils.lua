local function clone_many_times(net, T)
  local clones = {}

  local params, gradParams
  if net.parameters then
    params, gradParams = net:parameters()
    if params == nil then
      params = {}
    end
  end

  local paramsNoGrad
  if net.parametersNoGrad then
    paramsNoGrad = net:parametersNoGrad()
  end

  -- look for all masks (pruned linear)
  local masksWeight = {}
  local masksBias = {}
  net:apply(function(m)
    if (m.negmaskWeight) then table.insert(masksWeight, m.negmaskWeight) end
    if (m.negmaskBias) then table.insert(masksBias, m.negmaskBias) end
  end)

  local mem = torch.MemoryFile("w"):binary()
  mem:writeObject(net)

  for t = 1, T do
    -- We need to use a new reader for each clone.
    -- We don't want to use the pointers to already read objects.
    local reader = torch.MemoryFile(mem:storage(), "r"):binary()
    local clone = reader:readObject()
    reader:close()

    if net.parameters then
      local cloneParams, cloneGradParams = clone:parameters()
      local cloneParamsNoGrad
      for i = 1, #params do
        cloneParams[i]:set(params[i])
        cloneGradParams[i]:set(gradParams[i])
      end
      if paramsNoGrad then
        cloneParamsNoGrad = clone:parametersNoGrad()
        for i =1,#paramsNoGrad do
          cloneParamsNoGrad[i]:set(paramsNoGrad[i])
        end
      end
    end

    -- if pruned models, use single copy of the boolean masks
    if #masksWeight>0 then
      local idxw=1
      local idxb=1
      clone:apply(function(m)
        if (m.negmaskWeight) then m.negmaskWeight=masksWeight[idxw];idxw=idxw+1 end
        if (m.negmaskBias) then m.negmaskBias=masksBias[idxb];idxb=idxb+1 end
      end)
    end

    clones[t] = clone
    collectgarbage()
  end

  mem:close()
  return clones
end

local function reset_state(state, batch_l, t)
  local new_state, table_to_fill
  if t == nil then
    new_state = {}
    table_to_fill = new_state
  else
    new_state = {[t] = {}}
    table_to_fill = new_state[t]
  end

  for i = 1, #state do
    state[i]:zero()
    table.insert(table_to_fill, state[i][{{1, batch_l}}])
  end
  return new_state
end

return {
  clone_many_times = clone_many_times,
  reset_state = reset_state
}
