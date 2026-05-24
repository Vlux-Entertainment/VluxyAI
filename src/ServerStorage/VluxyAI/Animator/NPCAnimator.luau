--!strict

--[[
	Note:

	Everything is in the constructor so the animation table has type checking.

	A build check should be added for the associated methods.

	There should be a check to make sure a track isn't loaded multiple times per entity.
]]

local ALMOST_ZERO = 0.001 -- to fix weight issue

export type ANIMATION_INFO = {
	ID: number,
	WEIGHTED: boolean,
	PRIORITY: Enum.AnimationPriority,
}

------------------------------------------------------------------------------------------------------------------------

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Trove = require(ReplicatedStorage.Packages.trove)

------------------------------------------------------------------------------------------------------------------------

--[[
	An animator class for NPCs that handles both weighted and unweighted animations.

	Weighted animations are animations that can be blended together, such as an idle animation and a walk animation. Unweighted animations are animations that cannot be blended together, such as a jump animation.

	The NPCAnimator class allows you to easily play and adjust both weighted and unweighted animations on an NPC.

	It is highly recommended that all animations are loaded on start. Adding more animations after can have unintended behavior if not handled properly.
]]
local NPCAnimator = {}

--[[
	Creates a new NPCAnimator.

	@param entity Model - the model of the NPC
	@param animations table - a table of animations, where the key is the name of the animation and the value is an ANIMATION_INFO table

	@return NPCAnimator The created NPCAnimator object.
]]
function NPCAnimator.new<_, T>(entity: Model, animations: T)
	local nPCAnimator = {}
	nPCAnimator._cleaner = Trove.new() :: typeof(Trove.new())

	nPCAnimator.entity = entity :: Model
	nPCAnimator.animator = entity:FindFirstChildOfClass("Animator") :: Animator

	nPCAnimator.animations = animations :: T
	nPCAnimator.LoadedAnimations = {} :: { [number]: AnimationTrack }

	--[[
		Builds the NPCAnimator by loading the animations.

		@param self NPCAnimator - the object
	]]
	function nPCAnimator.Build(self: NPCAnimator)
		assert(nPCAnimator.animator, "Could not find animator inside entity! " .. entity:GetFullName())

		-- load animation tracks
		for name, info in pairs(self.animations :: any) do
			self:LoadAnimation(name, info)
		end

		return self
	end

	--[[
		Plays a weighted animation.

		@param self NPCAnimator - the object
		@param id number - the id of the animation to play
		@param fade number? - the fade time of the animation
		@param weight number? - the weight of the animation
		@param speed number? - the speed of the animation

		@return self The NPCAnimator object, allowing for method chaining.
	]]
	function nPCAnimator.AdjustWeightedAnimation(self: NPCAnimator, id: number, weight: number)
		local selfAnimations = self.animations :: any
		local animationInfo = selfAnimations[id] :: ANIMATION_INFO

		local animation = self.LoadedAnimations[id]

		if not animation then
			warn("Animation with id " .. id .. " not found!")
			return
		end
		if not animationInfo.WEIGHTED then
			warn("Animation with id " .. id .. " is not weighted!")
			return
		end

		animation:AdjustWeight(math.max(ALMOST_ZERO, weight))

		return self
	end

	--[[
		Plays an unweighted animation.

		@param self NPCAnimator - the object
		@param id number - the id of the animation to play
		@param fade number? - the fade time of the animation
		@param weight number? - the weight of the animation
		@param speed number? - the speed of the animation

		@return self The NPCAnimator object, allowing for method chaining.
	]]
	function nPCAnimator.PlayUnweightedAnimation(
		self: NPCAnimator,
		id: number,
		fade: number?,
		weight: number?,
		speed: number?
	)
		local selfAnimations = self.animations :: any
		local animationInfo = selfAnimations[id] :: ANIMATION_INFO

		local animation = self.LoadedAnimations[id]

		if not animation then
			warn("Animation with id " .. id .. " not found!")
			return
		end
		if animationInfo.WEIGHTED then
			warn("Animation with id " .. id .. " is weighted!")
			return
		end

		animation:Play(fade, weight, speed)

		return self
	end

	--[[
		Stops an unweighted animation.

		@param self NPCAnimator - the object
		@param id number - the id of the animation to stop
		@param fade number? - the fade time of the animation

		@return self The NPCAnimator object, allowing for method chaining.
	]]
	function nPCAnimator.StopUnweightedAnimation(self: NPCAnimator, id: number, fade: number?)
		local selfAnimations = self.animations :: any
		local animationInfo = selfAnimations[id] :: ANIMATION_INFO

		local animation = self.LoadedAnimations[id]

		if not animation then
			warn("Animation with id " .. id .. " not found!")
			return
		end
		if animationInfo.WEIGHTED then
			warn("Animation with id " .. id .. " is weighted!")
			return
		end

		animation:Stop(fade)

		return self
	end

	--[[
		Loads an animation and returns the AnimationTrack.

		@param self NPCAnimator - the object
		@param name string - the name of the animation
		@param info ANIMATION_INFO - the information of the animation

		@return AnimationTrack The loaded AnimationTrack.
	]]
	function nPCAnimator.LoadAnimation(self: NPCAnimator, name: string, info: ANIMATION_INFO)
		local animation = Instance.new("Animation")
		animation.AnimationId = "rbxassetid://" .. info.ID
		animation.Name = name
		animation.Parent = self.entity

		local loadedAnimation = self.animator:LoadAnimation(animation)
		loadedAnimation.Priority = info.PRIORITY
		loadedAnimation.Looped = info.WEIGHTED
		loadedAnimation:AdjustSpeed(1)

		if info.WEIGHTED then
			loadedAnimation:Play()
			loadedAnimation:AdjustWeight(ALMOST_ZERO)
		end

		self.LoadedAnimations[info.ID] = loadedAnimation

		--cleanup
		self._cleaner:Add(function()
			loadedAnimation:Stop()
			loadedAnimation:Destroy()

			animation:Destroy()

			self.LoadedAnimations[info.ID] = nil
		end)

		return self
	end

	--[[
		Returns the animations of the NPC.

		@param self NPCAnimator - the object

		@return T The animations of the NPC.
	]]
	function nPCAnimator.GetAnimationInfo(self: NPCAnimator): T
		return self.animations
	end

	--[[
		Returns a loaded AnimationTrack by its id.

		@param self NPCAnimator - the object
		@param id number - the id of the animation

		@return AnimationTrack The loaded AnimationTrack.
	]]
	function nPCAnimator.GetLoadedAnimation(self: NPCAnimator, id: number): AnimationTrack
		local loadedAnimation = self.LoadedAnimations[id]

		if not loadedAnimation then
			error("Animation with id " .. id .. " not found!")
		end

		return loadedAnimation
	end

	--[[
		Cleans up the object.

		@param self NPCAnimator - the object
	]]
	function nPCAnimator.Cleanup(self: NPCAnimator)
		self._cleaner:Clean()
	end

	type NPCAnimator = typeof(nPCAnimator)

	--this allows you to stack methods on the constructor
	local self = nPCAnimator
	return self
end

return NPCAnimator
