local unicode = require 'tools.utils.unicode'

local BPE = torch.class('BPE')

function BPE:__init(codesfile_path)
  self.codes = {}
  local f = assert(io.open(codesfile_path, "r"))
  local t = f:read("*line")
  local i = 1

  while not(t == nil) do
    local l=string.split(t, " ")
    if #l==2 then
      self.codes[t] = i
      i = i + 1
    end
    t=f:read("*line")
  end
end

local function getPairs(word)
  local pairs = {}
  for i = 1, #word-1, 1 do
    table.insert(pairs, word[i] .. ' ' .. word[i+1])
  end
  return pairs
end

local function str2word(l)
  local word = {}
  for _, c in unicode.utf8_iter(l) do
    table.insert(word, c)
  end
  table.insert(word, '</w>')
  return word
end

function BPE:minPair(pairsTable)
  local mintmp = 100000
  local minpair = ''
  for i = 1, #pairsTable, 1 do
    local pair_cur = pairsTable[i]
    if self.codes[pair_cur] then
      local scoretmp = self.codes[pair_cur]
      if (scoretmp < mintmp) then
        mintmp = scoretmp
        minpair = pair_cur
      end
    end
  end
  return minpair
end

function BPE:encode(l)
  local _, nextc = unicode._utf8_to_cp(l, 1)
  if #l <= #nextc then
    local w = {}
    table.insert(w, l)
    return w
  end
  local word = str2word(l)
  local pairs = getPairs(word)
  while true do
    local bigram = self:minPair(pairs)
    if bigram == '' then break end
    bigram = string.split(bigram, ' ')
    local new_word = {}
    local merge = false
    for _, xx in ipairs(word) do
      if (merge) then
        if xx == bigram[2] then
          table.insert(new_word, bigram[1] .. bigram[2])
          merge = false
        elseif (xx == bigram[1]) then
          table.insert(new_word, bigram[1])
        else
          table.insert(new_word, bigram[1])
          table.insert(new_word, xx)
          merge = false
        end
      else
        if bigram[1] == xx then
          merge = true
        else
          table.insert(new_word, xx)
        end
      end
    end
    word = new_word
    if #word == 1 then
      break
    else
      pairs = getPairs(word)
    end
  end
  if word[#word] == '</w>' then
    table.remove(word, #word)
  elseif (string.sub(word[#word],-string.len('</w>'))=='</w>') then
    word[#word] = string.sub(word[#word], 1, -string.len('</w>')-1)
  end
  return word
end

function BPE:segment(tokens, separator)
  local bpeSegment = {}
  for i=1, #tokens do
    local bpeTokens = self:encode(tokens[i])
    for j=1, #bpeTokens-1 do
      table.insert(bpeSegment, bpeTokens[j] .. separator)
    end
    table.insert(bpeSegment, bpeTokens[#bpeTokens])
  end
  return bpeSegment
end

return BPE
