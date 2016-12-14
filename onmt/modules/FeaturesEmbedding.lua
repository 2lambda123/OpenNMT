--[[
  A nngraph unit that maps features ids to embeddings. When using multiple
  features this can be the concatenation or the sum of each individual embedding.
]]
local FeaturesEmbedding, parent = torch.class('onmt.FeaturesEmbedding', 'nn.Container')

function FeaturesEmbedding:__init(dicts, dimExponent, dim, merge)
  parent.__init(self)

  self.net = self:_buildModel(dicts, dimExponent, dim, merge)
  self:add(self.net)
end

function FeaturesEmbedding:_buildModel(dicts, dimExponent, dim, merge)
  local inputs = {}
  local output

  if merge == 'sum' then
    self.outputSize = dim
  else
    self.outputSize = 0
  end

  self.embs = {}

  for i = 1, #dicts do
    local feat = nn.Identity()() -- batch_size
    table.insert(inputs, feat)

    local vocabSize = dicts[i]:size()
    local embSize

    if merge == 'sum' then
      embSize = self.outputSize
    else
      embSize = math.floor(vocabSize ^ dimExponent)
      self.outputSize = self.outputSize + embSize
    end

    self.embs[i] = onmt.WordEmbedding(vocabSize, embSize)
    local emb = self.embs[i](feat)

    if not output then
      output = emb
    elseif merge == 'sum' then
      output = nn.CAddTable()({output, emb})
    else
      output = nn.JoinTable(2)({output, emb})
    end
  end

  return nn.gModule(inputs, {output})
end

function FeaturesEmbedding:updateOutput(input)
  self.output = self.net:updateOutput(input)
  return self.output
end

function FeaturesEmbedding:updateGradInput(input, gradOutput)
  return self.net:updateGradInput(input, gradOutput)
end

function FeaturesEmbedding:accGradParameters(input, gradOutput, scale)
  self.net:accGradParameters(input, gradOutput, scale)
end

function FeaturesEmbedding:share(other, ...)
  for i = 1, #self.embs do
    self.embs[i]:share(other.embs[i], ...)
  end
end
