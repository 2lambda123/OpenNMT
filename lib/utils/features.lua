local constants = require('lib.constants')

--[[ Separate words and features (if any). ]]
local function extract(tokens)
  local words = {}
  local features = {}
  local num_features = nil

  for t = 1, #tokens do
    local field = utils.String.split(tokens[t], '%-|%-')
    local word = field[1]

    if word:len() > 0 then
      table.insert(words, word)

      if num_features == nil then
        num_features = #field - 1
      else
        assert(#field - 1 == num_features,
               'all words must have the same number of features')
      end

      if #field > 1 then
        for i = 2, #field do
          if features[i - 1] == nil then
            features[i - 1] = {}
          end
          table.insert(features[i - 1], field[i])
        end
      end
    end
  end
  return words, features, num_features or 0
end

--[[ Reverse operation: attach features to tokens. ]]
local function annotate(tokens, features, dicts)
  if not features or #features == 0 then
    return tokens
  end

  for i = 1, #tokens do
    for j = 1, #features[i + 1] do
      tokens[i] = tokens[i] .. '-|-' .. dicts[j]:lookup(features[i + 1][j])
    end
  end

  return tokens
end

--[[ Check that data contains the expected number of features. ]]
local function check(label, dicts, data)
  local expected = #dicts
  local got = 0
  if data ~= nil then
    got = #data
  end

  assert(expected == got, "expected " .. expected .. " " .. label .. " features, got " .. got)
end

--[[ Generate source sequences from labels. ]]
local function generateSource(dicts, src)
  check('source', dicts, src)

  local src_id = {}

  for j = 1, #dicts do
    table.insert(src_id, dicts[j]:convert_to_idx(src[j], constants.UNK_WORD))
  end

  return src_id
end

--[[ Generate target sequences from labels. ]]
local function generateTarget(dicts, tgt)
  check('source', dicts, tgt)

  local tgt_id = {}

  for j = 1, #dicts do
    -- Target features are shifted relative to the target words.
    -- Use EOS tokens as a placeholder.
    table.insert(tgt[j], 1, constants.BOS_WORD)
    table.insert(tgt[j], 1, constants.EOS_WORD)
    table.insert(tgt_id, dicts[j]:convert_to_idx(tgt[j], constants.UNK_WORD))
  end

  return tgt_id
end

return {
  extract = extract,
  annotate = annotate,
  generateSource = generateSource,
  generateTarget = generateTarget
}
