local GroupService = game:GetService("GroupService")
local MarketplaceService = game:GetService("MarketplaceService")
local Players = game:GetService("Players")
local TextService = game:GetService("TextService")

local Data = require(script.Parent.Data)
local Remote = require(script.Parent.Remote)
local Util = require(script.Parent.Util)

export type Role = "defaultRole" | "vip" | "mod" | "admin" | "superadmin" | "creator"

--- @class Auth
local Auth = {}

local function roleSort(a: Role, b: Role): boolean
	return Data.roles[a]._rank > Data.roles[b]._rank
end

function Auth.banHandler(player)
	local key = tostring(player.UserId)
	local banInfo = Data.bans[key]
	-- TODO: should staff roles bypass bans? add a settings toggle
	if not banInfo or player.UserId == Data.creatorId then
		-- not banned
		return
	end

	local reason, timeStamp = unpack(banInfo)
	local banMessage
	if tonumber(timeStamp) then
		if timeStamp > 0 then
			local timeRemaining = timeStamp - os.time()
			if timeRemaining > 0 then
				banMessage = "You are banned from this experience for " .. Util.ReadableTime(timeRemaining) .. "!"
			else
				-- unbanning
				Data.bans[key] = nil
				Data.Cache.bans[key] = Data.Store.REMOVE
				return
			end
		else
			banMessage = "You are permanently banned from this experience!"
		end
	else
		banMessage = "You are banned from this server!"
	end

	player:Kick(if reason then banMessage .. "\n Reason: " .. reason else banMessage)
	return true
end

function Auth.userBan(userId: number, reason: string, duration: number?, fromUserId: number)
	print("userBan", userId)
	local timestamp
	if duration and duration ~= 0 then -- and canBan?
		timestamp = if duration > 0 then os.time() + duration else -1
	end

	local key = tostring(userId)
	Data.bans[key] = { reason, timestamp, fromUserId }
	if tonumber(duration) and duration ~= 0 then
		Data.Cache.bans[key] = Data.bans[key]
		Data.pendingSaveMain = true
	end

	if not reason then
		local ban = { "No reason.", timestamp, fromUserId }
		for _, player in Players:GetPlayers() do
			-- TODO: only send to authorized clients!
			Remote.Ban:FireClient(player, key, ban)
		end
		return
	end

	local ok, result =
		pcall(TextService.FilterStringAsync, TextService, reason, fromUserId, Enum.TextFilterContext.PrivateChat)
	if ok then
		for _, player in Players:GetPlayers() do
			-- TODO: only send to authorized clients!
			local _, filtered = pcall(result.GetChatForUserAsync, result, player.UserId)
			Remote.Ban:FireClient(player, key, { filtered, timestamp, fromUserId })
		end
	end
end

function Auth.userUnban(userId: number, fromUserId: number)
	local key = tostring(userId)
	Data.bans[key] = nil
	Data.Cache.bans[key] = Data.Store.REMOVE
	Data.pendingSaveMain = true
	-- TODO: only send to authorized clients
	Remote.Ban:FireAllClients(userId)
end

--- Adds a role to a user if they don't already have it
-- TODO: make a way to define permanent vs temporary roles
function Auth.userRoleAdd(userId: number, role: Role, persist: boolean?): boolean
	local member = Data.members[tostring(userId)]
	local roleAdded = false
	if not member then
		local player = Players:GetPlayerByUserId(userId)
		Data.members[tostring(userId)] = {
			name = if player then player.Name else Players:GetNameFromUserIdAsync(userId),
			roles = { role },
			persist = { if persist then role else nil },
		}
		roleAdded = true
	else
		if not table.find(member.roles, role) then
			table.insert(member.roles, role)
			table.sort(member.roles, roleSort)
			if persist then
				table.insert(member.persist, role)
				table.sort(member.persist, roleSort)
			end
			roleAdded = true
		end
	end

	if roleAdded then
		-- TODO: only network to authorized clients and user client
		Remote.Members:FireAllClients(Data.members)
	end

	if persist and roleAdded then
		local key = tostring(userId)
		local cache = Data.Cache.members
		local player = Players:GetPlayerByUserId(userId)

		cache[key] = cache[key] or { if player then player.Name else Players:GetNameFromUserIdAsync(userId) }
		cache[key][2] = Data.members[key].persist
		Data.pendingSaveMain = true

		print("attempting permanent save", cache[key])
	end

	return roleAdded
end

--- Removes a role from a user if it exists
function Auth.userRoleRemove(userId: number, role: Role): boolean
	local member = Data.members[tostring(userId)]
	local roleRemoved = false
	local persistent = false
	if member then
		local index = table.find(member.roles, role)
		if index then
			table.remove(member.roles, index)
			roleRemoved = true
		end
		index = table.find(member.persist, role)
		if index then
			table.remove(member.persist, index)
			roleRemoved = true
			persistent = true
		end
	end

	if roleRemoved then
		-- TODO: only network to authorized clients and user client
		Remote.Members:FireAllClients(Data.members)
	end

	if persistent then
		local key = tostring(userId)
		local cache = Data.Cache.members
		local player = Players:GetPlayerByUserId(userId)

		cache[key] = cache[key] or { if player then player.Name else Players:GetNameFromUserIdAsync(userId) }
		cache[key][2] = Data.members[key].persist
		Data.pendingSaveMain = true
	end

	return roleRemoved
end

local asyncRolesCache = {}
function Auth.userAsyncRoles(userId: number, flushCache: boolean?)
	print(asyncRolesCache[userId])
	if asyncRolesCache[userId] and not flushCache then
		return
	end
	asyncRolesCache[userId] = true

	-- FIX: need to silently remove players who failed to have roles properly checked to prevent banid/unroleid on higher rank users

	local shouldNetwork

	-- gamepass permissions
	for gamePassId, roles in Data.async.gamepass do
		if MarketplaceService:UserOwnsGamePassAsync(userId, gamePassId) then
			for _, role in roles do
				Auth.userRoleAdd(userId, role)
				shouldNetwork = true
			end
		end
	end

	-- group permissions
	if next(Data.async.group) then
		local ok, groups = pcall(function()
			return GroupService:GetGroupsAsync(userId)
		end)
		if not ok then
			-- return false
		end
		for _, group in groups do
			local groupAuth = Data.async.group[group.Id]
			if groupAuth then
				for _, auth in groupAuth do
					if group.Rank == auth.rank or (not auth.exactRank and group.Rank >= auth.rank) then
						for _, role in auth.roles do
							Auth.userRoleAdd(userId, role)
							shouldNetwork = true
						end
					end
				end
			end
		end
	end

	if shouldNetwork then
		-- network the changes to roles
	end

	-- the following requires a player instance
	local player = Players:GetPlayerByUserId(userId)
	if not player then
		return
	end

	-- legacy asset permissions
	for assetId, roles in Data.async.asset do
		if MarketplaceService:PlayerOwnsAsset(player, assetId) then
			for _, role in roles do
				Auth.userRoleAdd(userId, role)
			end
		end
	end

	-- subscription permissions
	for subscriptionId, roles in Data.async.subscription do
		local ok, result =
			pcall(MarketplaceService.GetUserSubscriptionStatusAsync, MarketplaceService, player, subscriptionId)
		if ok and result.IsSubscribed then
			for _, role in roles do
				Auth.userRoleAdd(userId, role)
			end
		end
	end
end

--- Checks the maximum role rank of the user, if permission is given it will fetch the highest rank of the roles with that permission
function Auth.getRank(userId: number, permission: string?): (number, Role)
	permission = permission or "_rank"
	local rank, rankRole = 0, Data.defaultRole
	local member = Data.members[tostring(userId)]
	if member then
		for _, roleId in member.roles do
			local role = Data.roles[roleId]
			if role and role[permission] then
				rank = math.max(rank, role._rank)
				rankRole = role
			end
		end
	end
	return rank, rankRole
end

function Auth.roleCommandFilter(roleData, command, boolean: boolean): boolean
	if not roleData.filter then
		return false
	end
	if roleData.filter[command.name] == boolean then
		return true
	end
	if command.aliases then
		for _, alias in command.aliases do
			if roleData.filter[alias] == boolean then
				return true
			end
		end
	end
	return false
end

--- Checks if a role has access to a command group
function Auth.roleCanUseCommand(role: Role, command): boolean
	local roleData = Data.roles[role]
	if not roleData then
		print(role)
		return false
	end
	if Auth.roleCommandFilter(roleData, command, false) then
		return false
	end
	local group = string.lower(command.group)
	if
		roleData.admin
		or Auth.roleCommandFilter(roleData, command, true)
		or (roleData.groups and table.find(roleData.groups, group))
	then
		return true
	end
	return false
end

--- Checks if a user has access to a command
function Auth.hasCommand(userId: number, command): boolean
	if Auth.roleCanUseCommand("defaultRole", command) then
		return true
	end

	local member = Data.members[tostring(userId)]
	if member then
		if member.permissions and member.permissions.admin then
			return true
		end
		for _, roleId in member.roles do
			local role = Data.roles[roleId]
			if not role then
				warn("undefined role?", role)
				continue
			end
			if Auth.roleCanUseCommand(roleId, command) then
				return true
			end
		end
	end
	return false
end

--- Checks if a user has access to a permission
function Auth.hasPermission(userId: number, permission: string): boolean
	-- does everyone have the permission?
	if Data.defaultRole[permission] or Data.defaultRole.admin then
		return true
	end
	local member = Data.members[tostring(userId)]
	if member then
		if member.permissions and (member.permissions.admin or member.permissions[permission]) then
			return true
		end
		for _, roleId in member.roles do
			local role = Data.roles[roleId]
			if role and (role.admin or role[permission]) then
				return true
			end
		end
	end
	return false
end

--- Gets the difference of two users' ranks, with an optional permission parameter
function Auth.rankDiff(userIdFrom: number, userIdTo: number, permission: string?)
	return Auth.getRank(userIdFrom, permission) - Auth.getRank(userIdTo, permission)
end

return Auth
