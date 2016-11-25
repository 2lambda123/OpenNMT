local constants = require 'lib.constants'

local WordEmbedding, parent = torch.class('onmt.WordEmbedding', 'nn.Module')

function WordEmbedding:__init(vocab_size, vec_size, pre_trained, fix)
  parent.__init(self)

  self.net = nn.LookupTable(vocab_size, vec_size)

  -- If embeddings are given. Initialize them.
  if pre_trained:len() > 0 then
    local vecs = torch.load(pre_trained)
    self.net.weight:copy(vecs)
  end

  self.fix = fix

  -- Padding should not have any value.
  self.net.weight[constants.PAD]:zero()
end

function WordEmbedding:updateOutput(input)
  self.output = self.net:updateOutput(input)
  return self.output
end

function WordEmbedding:updateGradInput(input, gradOutput)
  return self.net:updateGradInput(input, gradOutput)
end

function WordEmbedding:accGradParameters(input, gradOutput, scale)
  self.net:accGradParameters(input, gradOutput, scale)

  if self.fix then
    -- Ignore gradients if embeddings are not to be optimized.
    self.net.gradWeight:zero()
  else
    -- Padding should not have any value.
    self.net.gradWeight[constants.PAD]:zero()
  end
end

function WordEmbedding:parameters()
  return self.net:parameters()
end
