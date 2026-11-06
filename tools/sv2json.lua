-- Dumps a SavedVariables file as JSON: lua51 sv2json.lua <file> <global>
local env = {}
setfenv(assert(loadfile(arg[1])), env)()
local function enc(v)
	local t = type(v)
	if t == "table" then
		local n = #v
		local isArr = n > 0
		for k in pairs(v) do if type(k) ~= "number" or k < 1 or k > n or k % 1 ~= 0 then isArr = false end end
		local out = {}
		if isArr then
			for i = 1, n do out[i] = enc(v[i]) end
			return "[" .. table.concat(out, ",") .. "]"
		end
		for k, x in pairs(v) do out[#out + 1] = string.format("%q", tostring(k)) .. ":" .. enc(x) end
		return "{" .. table.concat(out, ",") .. "}"
	elseif t == "string" then return string.format("%q", v)
	elseif t == "number" then return string.format("%.10g", v)
	elseif t == "boolean" then return tostring(v)
	else return "null" end
end
io.write(enc(env[arg[2]]))
