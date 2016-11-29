--[[ Append table `src` to `dst`. ]]
local function append(dst, src)
  for i = 1, #src do
    table.insert(dst, src[i])
  end
end

--[[ Reorder table `tab` based on the `index` array. ]]
local function reorder(tab, index)
  local new_tab = {}
  for i = 1, #tab do
    table.insert(new_tab, tab[index[i]])
  end
  return new_tab
end

local function map(tab, fun)
  for i = 1, #tab do
    tab[i] = fun(tab[i])
  end
  return tab
end

return {
  map = map,
  reorder = reorder,
  append = append
}
