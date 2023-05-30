local PlayerHandler = require(game.ServerScriptService.Modules.PlayerHandler)
local RoundObj = require(game.ServerScriptService.Modules.RoundObj)
local GameSettings = require(game.ServerScriptService.Modules.Info.GameSettings)

local reviveEvent = require(game:GetService("ReplicatedStorage").Modules.RemoteMod)
local gui = game.ReplicatedStorage.Guis.ReviveGUI
local gameStatus = game.ReplicatedStorage.GameStatus

local reviveDist = 16 --max dist in studs
local bleedRate = 4	--amnt lost per sec
local regenRate = 19	--amnt gained per sec
local startHealth = 60
local amountLostPerDowned = 40
local amountCanBeDowned = 2

local downedPlrs = {}

local module = {}
module.__index = module

function module.new(plr, murdered)
	local chara = plr and plr.Character or nil
	local class = PlayerHandler.GetPlayer(plr)
	if not chara or not class then return end
	
	local obj = setmetatable({},module)
	obj.gui = gui:Clone()
	obj.player = plr
	obj.char = chara
	obj.isReviving = false
	obj.health = startHealth
	obj.murdered = murdered
	obj.maxHealth = string.find(class.Equipped[plr.Role.Value].Perk, "Health_") and GameSettings.PerkConfigs[class.Equipped[plr.Role.Value].Perk].Health or 100
	
	local part = Instance.new("Part")
	part.Name = "ReviveRadius"
	part.CanCollide = false
	part.Transparency = 1
	part.CFrame = obj.char.HumanoidRootPart.CFrame
	
	local weld = Instance.new("WeldConstraint")
	weld.Parent = obj.char.HumanoidRootPart
	weld.Part0 = obj.char.HumanoidRootPart
	weld.Part1 = part
	
	part.Parent = obj.char.HumanoidRootPart
	part.Size = Vector3.new(reviveDist, reviveDist, reviveDist)
	
	obj.region = part
	
	obj.gui.Parent = obj.char.HumanoidRootPart
	plr.Downed.Value = true
	downedPlrs[plr] = obj
	reviveEvent.SendClient(obj.player, "Crawling-Event", true)
	
	local currentRound = RoundObj.getCurrentRound()
	if currentRound.PreviouslyDowned[plr.Name] then
		currentRound.PreviouslyDowned[plr.Name] += 1
	else
		currentRound.PreviouslyDowned[plr.Name] = 1
	end
	
	obj:connectBar()
	obj:parentGUIs()
	
	return obj
end

function module:parentGUIs()
	PlayerHandler.FindPlayersWithProperty("State", "Alive", function(v)
		reviveEvent.SendClient(v.Player, "Input-Event", "gui", "toggle-revive-gui", self.char.HumanoidRootPart, true)
	end)
end

function module:checkArea()
	local part = self.region
	local region = Region3.new(part.Position - part.Size / 2, part.Position + part.Size / 2)
	local killerCamping = false
	local numOfRevivers = {}
	for _, v in ipairs(workspace:FindPartsInRegion3WithIgnoreList(region, {self.char}, math.huge)) do
		if v.Parent then
			local plr = game.Players:GetPlayerFromCharacter(v.Parent)
			if plr and plr.State.Value == "Alive" and plr.Character.Humanoid.Health ~= 0 then 
				if plr.Role.Value ~= "Killer" and not plr.Downed.Value and not table.find(numOfRevivers, plr.Name) then
					table.insert(numOfRevivers, plr.Name)
				elseif plr.Role.Value == "Killer" then
					killerCamping = true
				end
			end
		end
	end
	local mltplier = #numOfRevivers == 1 and 1 or #numOfRevivers > 1 and (10 + #numOfRevivers) / 10 or 0
	return (#numOfRevivers ~= 0), mltplier, killerCamping
end

function module:connectBar()
	local healthbar = self.gui.Bar.Frame
	local origSize = healthbar.Size
	self.healthConnection = coroutine.create(function(obj)
		if RoundObj.getCurrentRound().PreviouslyDowned[obj.player.Name] <= amountCanBeDowned then
			local dt = tick()
			while true do wait()
				local numOfRevivers = 0
				local isCamped = false
				obj.isReviving, numOfRevivers, isCamped = obj:checkArea()
				healthbar.Parent.CampLabel.Visible = (isCamped and not obj.isReviving)
				local off = 1 / (tick() - dt)
				if obj.isReviving then
					obj.health = math.clamp(obj.health + ((regenRate * numOfRevivers) / off), 0, 100)
					healthbar.BackgroundColor3 = Color3.fromRGB(85, 255, 0)
				elseif isCamped then
					healthbar.BackgroundColor3 = Color3.fromRGB(104, 104, 104)
				elseif not obj.isReviving then
					obj.health = math.clamp(obj.health - (bleedRate / off), 0, 100)
					healthbar.BackgroundColor3 = Color3.fromRGB(243, 22, 22)
				end
				local percent = obj.health/100 >= .1 and obj.health/100 or .1
				healthbar.Size = UDim2.new(origSize.X.Scale * percent, 0, origSize.Y.Scale, 0)
				healthbar.Position = UDim2.new(0.5 - ((origSize.X.Scale - healthbar.Size.X.Scale) / 2), 0, 0.5, 0)
				dt = tick()
				if obj.health >= 100 or obj.health <= 0 or gameStatus.Value ~= "Ingame" then break end
				local numDowned = #PlayerHandler.FindPlayersWithProperty("Downed",true)
				if numDowned == #PlayerHandler.FindPlayersWithProperty("State","Alive") - 1 or numDowned == #PlayerHandler.FindPlayersWithProperty("Role", "Survivor") or game.ReplicatedStorage.Timer.Value < 15 then 
					obj.health = 0
					break
				end
			end
		else
			obj.health = 0
		end
		obj:changeState()
	end)
	local result, err = coroutine.resume(self.healthConnection,self)
	if not result then warn(err) end
end

function module:changeState()
	if self.char:FindFirstChild("HumanoidRootPart") then
		reviveEvent.SendAllClients("Input-Event", "gui", "toggle-revive-gui", self.char.HumanoidRootPart, false)
	end
	local health = self.health
	if health == 0 then
		self.char.Humanoid.Health = 0
		if self.murdered then
			local killer do
				killer = PlayerHandler.FindPlayersWithProperty("Role", "Killer")[1]
			end
			RoundObj.getCurrentRound():modifyKills("add", self.player.Name, killer)
		end
		for _, v in ipairs(PlayerHandler.FindPlayersWithProperty("State", "Alive")) do
			reviveEvent.SendClient(v.Player, "Input-Event", "music", "death")
		end
	else
		local numTimesDowned = RoundObj.getCurrentRound().PreviouslyDowned[self.player.Name]
		self.char.Humanoid.Health = self.maxHealth - 50--(numTimesDowned * amountLostPerDowned)
		reviveEvent.SendClient(self.player, "Crawling-Event", false)
		coroutine.wrap(function()
			local force = Instance.new("ForceField")
			force.Parent = self.char
			wait(4)
			force:Destroy()
		end)()
	end
	self:disconnect()
end

function module.getDownedPlayer(plr)
	return downedPlrs[plr]
end

function module:disconnect()
	self.healthConnection = nil
	self.gui:Destroy()
	self.region:Destroy()
	self.player.Downed.Value = false
	downedPlrs[self.player] = nil
	self = nil
	
end

return module
