-- Ink Game uncertainty-aware intent-ensemble auto dodge v7.3 (PC)
-- F1 toggles the system. It starts OFF.
--
-- Stability design:
--   * No getgc/decompile/remote-spy work at runtime.
--   * Phantom Step reads its current controller stack through one bounded,
--     cached Info-connection lookup; no repeated global scan is performed.
--   * No simulation loop while OFF.
--   * Exactly one bounded PreSimulation engine while ON.
--   * Hard caps on character watchers and pending attacks.
--   * Every connection is disconnected on OFF, respawn, removal, or re-run.
--   * Uses the game's native Main.Info dash path, which applies its own rules.
--   * A single frame deadline bounds animation, projectile, and MPC work.
--   * V7 models five bounded attacker intents and treats unfinished solver
--     work as unsafe instead of assuming an unevaluated route is clear.

if not game:IsLoaded() then
    game.Loaded:Wait()
end

if game.GameId ~= 7008097940 then
    warn("[Ink Auto Dodge] Wrong universe: " .. tostring(game.GameId))
    return
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

if not UserInputService.KeyboardEnabled then
    warn("[Ink Auto Dodge] PC keyboard version only")
    return
end

local LocalPlayer = Players.LocalPlayer
local Values = workspace:WaitForChild("Values", 10)
local Live = workspace:WaitForChild("Live", 10)
local Effects = workspace:FindFirstChild("Effects")
if not Values or not Live then
    warn("[Ink Auto Dodge] Values/Live did not replicate in time")
    return
end

local Environment = getgenv and getgenv() or _G
local Previous = Environment.__INK_GAME_AUTO_DODGE
if Previous and type(Previous.Destroy) == "function" then
    pcall(Previous.Destroy, Previous)
end

local MAX_WATCHERS = 128
local MAX_PENDING = 32
local MAX_PROJECTILES = 48
local MAX_WEAPON_PARTS = 16
local MAX_ERRORS = 5
local MAX_DIRECTION_THREATS = 6
local MAX_DIRECTION_CANDIDATES = 12
local MAX_DIRECTION_SAMPLES = 16
local MAX_SWEEP_STEPS = 20
local MAX_PREDICTION_TIME = 1.35
local MAX_MPC_DELAYS = 4
local MAX_PATH_HYPOTHESES = 5
local MAX_MPC_SHORTLIST = 6
local MAX_MPC_SAMPLES = 12
local MAX_MPC_TESTS = 2200
local MAX_REPLAY_SAMPLES = 96
local MAX_DYNAMIC_ANIMATIONS = 48
local MAX_SHADOW_ANIMATIONS = 64
local PROJECTILE_HISTORY_LIMIT = 8
local MAX_PREDICTED_BOUNCES = 2
local MPC_ARM_WINDOW = 0.32
local MPC_MAX_DELAY = 0.28
local MPC_REPLAN_INTERVAL = 0.04
local MPC_COMMIT_WINDOW = 0.04
local MPC_WORK_BUDGET = 0.0035
local POST_DODGE_HORIZON = 0.62
local NEAR_SAMPLE_RANGE = 180
local PROJECTILE_ACQUISITION_RANGE = 260
local PROJECTILE_HARD_TTL = 6
local WEAPON_SAMPLE_HORIZON = 0.22
local WEAPON_SAMPLE_TTL = 0.12
local FAR_SAMPLE_INTERVAL = 1 / 15
local PING_SAMPLE_INTERVAL = 0.25
local DASH_LINK_WINDOW = 0.8
local DASH_CLOSING_SPEED = 48
local DASH_CLOSING_ACCELERATION = 180
local DASH_ACK_TIMEOUT = 0.15
local MAX_DASH_ACK_LOCK = 0.28
local DASH_STATE_RETRY_INTERVAL = 1
local DASH_CONFIRM_HOLD = 0.14
local DASH_CONFIRM_DOT = 0.4
local DASH_CONFIRM_MIN_SPEED = 18
local QUEUE_MARGIN = 3
local MIN_REQUEST_INTERVAL = 0.035
local REQUEST_BUDGET_WINDOW = 2
local MAX_REQUESTS_PER_WINDOW = 4
local POST_ACTIVE_TOLERANCE = 0.025
local BODY_RADIUS = 2.15
local BODY_HALF_HEIGHT = 2.55
local ZERO = Vector3.zero
local DIRECTION_SAMPLE_TIMES = { 0.04, 0.08, 0.14, 0.22, 0.34, 0.5 }

local State = {
    Version = 7.3,
    Enabled = false,
    Initializing = false,
    Destroyed = false,
    Generation = 0,
    ToggleKey = Enum.KeyCode.F1,
    PhantomStepPower = "PHANTOM STEP",
    PhantomStepDuration = 0.05,
    PhantomStepDirectionScale = 7,
    PhantomStepBaseSpeed = 27,
    PhantomStepMaxStacks = 2,
    PhantomStackClearGrace = 0.12,
    PhantomSettleInterval = 0.12,
    PhantomTerrainSafetyScale = 1.12,
    FlingGuardWindow = 0.16,
    FlingBrakeDuration = 0.07,
    FlingHorizontalFactor = 1.32,
    FlingHorizontalMargin = 28,
    FlingVerticalLimit = 70,
    FlingAngularLimit = 45,
    FlingDisplacementFactor = 1.55,
    FlingDisplacementMargin = 5,
    StrictPhantomGroundSafety = true,
    GroundProbeSpacing = 1.25,
    MaximumAdaptiveGroundSpacing = 2,
    GroundFootprintRadius = 1.8,
    GroundProbeRise = 3.5,
    GroundProbeDepth = 14,
    GroundMinimumNormalY = 0.5,
    PhantomGroundMinimumNormalY = 0.72,
    MinimumGroundClearance = 1.5,
    MaximumGroundClearance = 4.25,
    MaximumSafeDrop = 3.25,
    MaximumGroundStep = 2.75,
    MaximumGroundSamples = 20,
    GroundSupportHorizon = 0.08,
    MaximumSupportMotion = 1.25,
    TerrainTravelMargin = 0.85,
    HazardNameSignals = {
        "killbrick", "killpart", "deathpart", "deathfloor",
        "damagefloor", "hazard", "lethal", "lava", "voidfloor",
        "breakaway", "fallingplatform", "trapdoor", "fakefloor",
    },
    HazardBooleanSignals = {
        "Kill", "Kills", "Hazard", "Lethal", "Breakaway",
        "Falling", "FakeFloor", "Unsafe", "Disappear",
    },
    MotionHistoryLimit = 8,
    MaxDashTelemetry = 4,
    DashCurveSampleTimes = { 0.04, 0.08, 0.14, 0.22, 0.34, 0.5 },

    Watchers = {},
    WatcherCount = 0,
    ActiveConnections = {},
    LifetimeConnections = {},
    ProjectileEffectsConnection = nil,
    Pending = {},
    PendingIndex = setmetatable({}, { __mode = "k" }),
    SeenTracks = setmetatable({}, { __mode = "k" }),
    PendingCount = 0,
    Engine = nil,
    LocalMotion = nil,
    TopThreats = {},
    EvaluationOrder = {},
    Projectiles = {},
    ProjectileList = {},
    ProjectileCount = 0,
    NextProjectileRescanAt = 0,
    ProjectileCandidatesSeen = 0,
    PhysicalProjectilesTracked = 0,
    PhysicalProjectileThreats = 0,
    LiveWeaponSamples = 0,
    LiveWeaponThreats = 0,
    CalibrationByKey = {},
    CalibrationSamples = 0,
    ServerClockOffset = 0,
    ServerClockDeviation = 0,
    ServerClockSamples = 0,
    DashStartupDeviation = 0.004,
    LastOptimizerCandidates = 0,
    LastMpcTests = 0,
    LastMpcMilliseconds = 0,
    LastMpcDelayCandidates = 0,
    LastMpcLatestDelay = 0,
    MpcBudgetAborts = 0,
    NextMpcAt = 0,
    DodgePlan = nil,
    LastActivationDelay = 0,
    LastPlanConfidence = 0,
    LastProjectileModel = "None",
    LastIntentModel = "Continue",
    LastIntentConfidence = 0,
    LastPathHypotheses = 1,
    LastTailRisk = 0,
    LastImpactEarliest = -1,
    LastImpactLatest = -1,
    LastEnvelopeComplete = true,
    IntentEnsembleEvaluations = 0,
    EnvelopeBudgetFallbacks = 0,
    ProvisionalProjectileThreats = 0,
    ThreatFusions = 0,
    TerrainRejectedDodges = 0,
    LastTerrainStatus = "Unchecked",
    LastFrameWork = 0,
    FrameWorkMean = 0,
    DecayingWorstWork = 0,
    FrameDeadline = 0,
    SuppressActions = false,
    Replay = table.create(MAX_REPLAY_SAMPLES),
    ReplayHead = 0,
    ReplayCount = 0,
    DynamicProfiles = {},
    DynamicProfileCount = 0,
    ShadowAnimations = {},
    ShadowAnimationCount = 0,

    Profiles = nil,
    DashIds = nil,
    ProfileBuiltAt = 0,
    NextProfileRefreshAt = 0,
    RecentEnemyDashes = setmetatable({}, { __mode = "k" }),
    ProfileCount = 0,
    ExactProfileCount = 0,
    AttackEvents = 0,
    RecognizedAttacks = 0,
    PredictedThreats = 0,
    SweptEmergencies = 0,
    DodgeAttempts = 0,
    DashReleases = 0,
    AcceptedDodges = 0,
    RejectedDodges = 0,
    LastRequestAt = -math.huge,
    LastAcceptedAt = -math.huge,
    RequestTimes = {},
    AttemptPending = nil,
    DirectionLease = nil,
    DirectionLeaseToken = 0,
    DirectionLeaseStarts = 0,
    DirectionLeaseRestores = 0,
    DirectionLeaseConflicts = 0,
    LastDirectionLeaseMs = 0,
    DirectionVerifiedDodges = 0,
    DirectionUnverifiedDodges = 0,
    PingMean = 0.05,
    PingDeviation = 0,
    NextPingSampleAt = 0,
    NextServerClockSampleAt = 0,
    FrameMean = 1 / 60,
    FrameDeviation = 0,
    DecayingWorstFrame = 1 / 60,
    DashStartupMean = 0.006,
    LastThreat = "None",
    LastDirection = "None",
    LastContactMilliseconds = 0,
    LastReactionMilliseconds = -1,
    LastAcknowledgementMilliseconds = -1,
    DashControllerCharacter = nil,
    DashControllerInfo = nil,
    DashControllerState = nil,
    DashControllerRetryAt = 0,
    PhantomFallbackCharacter = nil,
    PhantomFallbackRecentDash = nil,
    PhantomFallbackStacks = 0,
    PhantomFallbackMarkerSeen = false,
    PhantomFallbackMarkerClearedAt = nil,
    PhantomChargesReady = 0,
    PhantomChargesMax = 0,
    PhantomStateSource = "Inactive",
    PhantomDashReleases = 0,
    DashCurveCalibration = {},
    DashTelemetry = {},
    DashSafety = nil,
    FlingBrakeUntil = 0,
    FlingGuardTrips = 0,
    MaximumObservedDashHorizontalSpeed = 0,
    MaximumObservedDashVerticalSpeed = 0,
    MaximumObservedDashAngularSpeed = 0,
    LastFlingGuardReason = "None",
    DashCalibrationKeyCharacter = nil,
    DashCalibrationKeyValue = nil,
    DashCalibrationKeyPhantom = nil,
    DashCalibrationKeyExpiresAt = 0,
    DashCalibrationSamples = 0,
    DashCalibrationRejects = 0,
    ErrorCount = 0,
    ConsecutiveErrors = 0,
    NextStatusAt = 0,
    LastEvaluatedThreats = 0,
    DeferredThreatEvaluations = 0,
    StaleThreatDrops = 0,
    ReachGateRejects = 0,
    FacingGateRejects = 0,
    RequestBudgetRollbacks = 0,
    LastBlockReason = "None",
    LastFrameGapMilliseconds = 0,
    MaximumFrameGapMilliseconds = 0,
    LastProcessAt = nil,
}
Environment.__INK_GAME_AUTO_DODGE = State

local releaseRequestSlot

local function disconnect(connection)
    if typeof(connection) == "RBXScriptConnection" then
        pcall(connection.Disconnect, connection)
    end
end

local function clearConnections(list)
    for index = #list, 1, -1 do
        disconnect(list[index])
        list[index] = nil
    end
end

local function normalizeAnimationId(value)
    return tostring(value or ""):match("%d+")
end

local function getValue(name, fallback)
    local object = Values:FindFirstChild(name)
    if object then
        local ok, value = pcall(function()
            return object.Value
        end)
        if ok then
            return value
        end
    end
    return fallback
end

local function getLocalCharacter()
    local character = LocalPlayer.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not character or not humanoid or not root or humanoid.Health <= 0 then
        return nil
    end
    return character, humanoid, root
end

local function resolveDashInfo(character)
    if not character then
        return nil
    end
    local controller = character:FindFirstChild("DashRequest")
        or character:FindFirstChild("Main")
    local info = controller and controller:FindFirstChild("Info")
    if info and info:IsA("BindableEvent") then
        return info
    end

    -- Controller names vary between client builds, but the native contract is
    -- consistently a direct-child script with a BindableEvent named Info.
    local scanned = 0
    for _, child in ipairs(character:GetChildren()) do
        scanned += 1
        if scanned > 48 then
            break
        end
        if child:IsA("LocalScript") or child:IsA("Script") then
            local candidate = child:FindFirstChild("Info")
            if candidate and candidate:IsA("BindableEvent") then
                return candidate
            end
        end
    end
    return nil
end

local function getNativeCooldown(character)
    local cooldown
    if getValue("CurrentGame", "") == "HideAndSeek" then
        cooldown = LocalPlayer:GetAttribute("IsHider") and 2.75 or 3
    else
        cooldown = 1.5
    end
    local rumorCooldown = character and character:FindFirstChild("RumorDashCooldown")
    if rumorCooldown then
        cooldown = math.max(
            cooldown,
            rumorCooldown:GetAttribute("Cooldown") or 2.5
        )
    end
    return cooldown
end

function State:GetEffectivePower(character)
    local overwrite = character and character:FindFirstChild("PowerOverwrite")
    if overwrite then
        local ok, value = pcall(function()
            return overwrite.Value
        end)
        if ok and type(value) == "string" and value ~= "" then
            return value
        end
    end
    return LocalPlayer:GetAttribute("_EquippedPower")
end

function State:IsPhantomStepActive(character)
    return self:GetEffectivePower(character) == self.PhantomStepPower
        and not getValue("PowersDisabled", false)
        and LocalPlayer:GetAttribute("IsGuard") ~= true
end

function State:PhantomUsesSingleChargeMode()
    local currentGame = getValue("CurrentGame", "")
    return currentGame == "SquidGame" or currentGame == "HideAndSeek"
end

function State:PhantomReadyCharges(stacks, singleCharge)
    stacks = math.clamp(
        math.floor((tonumber(stacks) or 0) + 0.5),
        0,
        self.PhantomStepMaxStacks
    )
    if singleCharge then
        return stacks < self.PhantomStepMaxStacks and 1 or 0, 1
    end
    return math.max(0, self.PhantomStepMaxStacks - stacks),
        self.PhantomStepMaxStacks
end

function State:ClearDashControllerCache()
    self.DashControllerCharacter = nil
    self.DashControllerInfo = nil
    self.DashControllerState = nil
    self.DashControllerRetryAt = 0
end

function State:ResolveDashControllerState(character)
    local now = os.clock()
    local cached = self.DashControllerState
    local cachedInfo = self.DashControllerInfo
    if self.DashControllerCharacter == character
        and cachedInfo and cachedInfo.Parent
        and type(cached) == "table"
        and type(rawget(cached, "CDDASHSTACKS")) == "number" then
        return cached
    end

    -- A missing/changed controller used to rescan getconnections/upvalues on
    -- every HUD refresh and every availability check.  Negative-cache that
    -- bounded probe so fallback mode cannot create a rhythmic hitch.
    if self.DashControllerCharacter == character
        and not cached
        and now < (self.DashControllerRetryAt or 0) then
        return nil
    end

    self:ClearDashControllerCache()
    self.DashControllerCharacter = character
    self.DashControllerRetryAt = now + DASH_STATE_RETRY_INTERVAL
    local info = resolveDashInfo(character)
    if not info or type(getconnections) ~= "function"
        or not debug or type(debug.getupvalues) ~= "function" then
        return nil
    end

    -- Info has one controller listener in the current client. Inspecting at
    -- most 12 listeners and 32 upvalues keeps this a bounded, one-time lookup.
    local ok, connections = pcall(getconnections, info.Event)
    if not ok or type(connections) ~= "table" then
        return nil
    end
    for connectionIndex = 1, math.min(#connections, 12) do
        local connection = connections[connectionIndex]
        local functionOk, callback = pcall(function()
            return connection.Function
        end)
        if functionOk and type(callback) == "function" then
            local upvalueOk, upvalues = pcall(debug.getupvalues, callback)
            if upvalueOk and type(upvalues) == "table" then
                local checked = 0
                for _, value in pairs(upvalues) do
                    checked += 1
                    if checked > 32 then
                        break
                    end
                    if type(value) == "table"
                        and type(rawget(value, "CDDASHSTACKS")) == "number" then
                        self.DashControllerCharacter = character
                        self.DashControllerInfo = info
                        self.DashControllerState = value
                        self.DashControllerRetryAt = 0
                        return value
                    end
                end
            end
        end
    end
    return nil
end

function State:ResetPhantomFallback(character)
    self.PhantomFallbackCharacter = character
    self.PhantomFallbackRecentDash = character
        and character:GetAttribute("RecentDash") or nil
    self.PhantomFallbackMarkerSeen = character
        and character:FindFirstChild("CDDASHSTACKSCD") ~= nil or false
    self.PhantomFallbackMarkerClearedAt = nil
    -- If the script starts while recovery is already active and the exact
    -- controller table is unavailable, block conservatively until it clears.
    self.PhantomFallbackStacks = self.PhantomFallbackMarkerSeen
        and self.PhantomStepMaxStacks or 0
end

function State:GetPhantomStackCount(character, now)
    local controllerState = self:ResolveDashControllerState(character)
    if controllerState then
        return math.clamp(
            math.floor((rawget(controllerState, "CDDASHSTACKS") or 0) + 0.5),
            0,
            self.PhantomStepMaxStacks
        ), "Controller"
    end

    if self.PhantomFallbackCharacter ~= character then
        self:ResetPhantomFallback(character)
    end
    local recentDash = character and character:GetAttribute("RecentDash")
    if type(recentDash) == "number"
        and recentDash ~= self.PhantomFallbackRecentDash then
        self.PhantomFallbackRecentDash = recentDash
        local spent = self:PhantomUsesSingleChargeMode()
            and self.PhantomStepMaxStacks or 1
        self.PhantomFallbackStacks = math.min(
            self.PhantomStepMaxStacks,
            self.PhantomFallbackStacks + spent
        )
    end

    local markerPresent = character
        and character:FindFirstChild("CDDASHSTACKSCD") ~= nil
    if markerPresent then
        self.PhantomFallbackMarkerSeen = true
        self.PhantomFallbackMarkerClearedAt = nil
    elseif self.PhantomFallbackMarkerSeen then
        self.PhantomFallbackMarkerClearedAt =
            self.PhantomFallbackMarkerClearedAt or now
        if now - self.PhantomFallbackMarkerClearedAt
            >= self.PhantomStackClearGrace then
            self.PhantomFallbackStacks = 0
            self.PhantomFallbackMarkerSeen = false
            self.PhantomFallbackMarkerClearedAt = nil
        end
    end
    return self.PhantomFallbackStacks, "Fallback"
end

function State:GetPhantomCharges(character, now)
    if not self:IsPhantomStepActive(character) then
        self.PhantomChargesReady = 0
        self.PhantomChargesMax = 0
        self.PhantomStateSource = "Inactive"
        return 0, 0, "Inactive"
    end
    local stacks, source = self:GetPhantomStackCount(character, now or os.clock())
    local singleCharge = self:PhantomUsesSingleChargeMode()
    local ready, maximum = self:PhantomReadyCharges(stacks, singleCharge)
    self.PhantomChargesReady = ready
    self.PhantomChargesMax = maximum
    self.PhantomStateSource = source
    return ready, maximum, source
end

local function nativeDashAvailable(character, humanoid)
    if not character or character.Parent ~= Live
        or not humanoid or humanoid.Health <= 0 then
        return false
    end
    if character:FindFirstChild("DisableDash")
        or character:FindFirstChild("Stun")
        or character:FindFirstChild("Dead")
        or character:FindFirstChild("Ragdoll") then
        return false
    end
    if getValue("CurrentGame", "") == "GlassBridge"
        and not character:GetAttribute("InSurgery") then
        return false
    end

    local boosts = LocalPlayer:FindFirstChild("Boosts")
    local fasterSprint = boosts and boosts:FindFirstChild("Faster Sprint")
    local phantomStep = State:IsPhantomStepActive(character)
    local unlocked = fasterSprint and fasterSprint.Value >= 5
        or workspace:GetAttribute("MaxSpeedBoosts")
        or phantomStep
    if not unlocked then
        return false
    end

    if phantomStep then
        local ready = State:GetPhantomCharges(character, os.clock())
        return ready > 0
    end

    local recentDash = character:GetAttribute("RecentDash")
    if type(recentDash) == "number"
        and tick() - recentDash < getNativeCooldown(character) then
        return false
    end
    if os.clock() - State.LastAcceptedAt < getNativeCooldown(character) then
        return false
    end
    return true
end

local StatusGui = Instance.new("ScreenGui")
StatusGui.Name = "InkAnimationAutoDodge"
StatusGui.ResetOnSpawn = false
StatusGui.IgnoreGuiInset = true
StatusGui.DisplayOrder = 1000000
StatusGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

local StatusLabel = Instance.new("TextLabel")
StatusLabel.Name = "Status"
StatusLabel.AnchorPoint = Vector2.new(0.5, 0)
StatusLabel.Position = UDim2.fromScale(0.5, 0.025)
StatusLabel.Size = UDim2.fromOffset(900, 148)
StatusLabel.BackgroundColor3 = Color3.fromRGB(15, 17, 23)
StatusLabel.BackgroundTransparency = 0.14
StatusLabel.BorderSizePixel = 0
StatusLabel.Font = Enum.Font.GothamBold
StatusLabel.TextSize = 15
StatusLabel.TextWrapped = true
StatusLabel.TextColor3 = Color3.fromRGB(255, 135, 135)
StatusLabel.Parent = StatusGui

local Corner = Instance.new("UICorner")
Corner.CornerRadius = UDim.new(0, 8)
Corner.Parent = StatusLabel

local function updateStatus(force)
    if State.Destroyed or not StatusLabel.Parent then
        return
    end
    local now = os.clock()
    if not force and now < State.NextStatusAt then
        return
    end
    State.NextStatusAt = now + 0.2
    local reactionText = State.LastReactionMilliseconds >= 0
        and string.format("%.2f ms", State.LastReactionMilliseconds)
        or "--"
    local acknowledgementText = State.LastAcknowledgementMilliseconds >= 0
        and string.format("%.2f ms", State.LastAcknowledgementMilliseconds)
        or "--"
    local impactText = State.LastImpactEarliest >= 0
        and string.format(
            "%d-%d ms",
            math.floor(State.LastImpactEarliest * 1000 + 0.5),
            math.floor(math.max(
                State.LastImpactEarliest,
                State.LastImpactLatest
            ) * 1000 + 0.5)
        ) or "--"
    local character = LocalPlayer.Character
    local dashText = "Normal"
    if State:IsPhantomStepActive(character) then
        -- Rendering must remain read-only and allocation-light.  The engine
        -- refreshes this cache; the HUD never performs controller discovery.
        local ready = State.PhantomChargesReady or 0
        local maximum = State.PhantomChargesMax or 0
        local source = State.PhantomStateSource or "Pending"
        dashText = string.format(
            "Phantom Step %d/%d (%s)",
            ready,
            maximum,
            source == "Controller" and "exact" or "safe"
        )
    end
    StatusLabel.TextColor3 = State.Enabled
        and Color3.fromRGB(135, 255, 165)
        or Color3.fromRGB(255, 135, 135)
    StatusLabel.Text = string.format(
        "BELIEF-SPACE AUTO DODGE v7.3: %s  [F1]  Dash: %s\nWatchers: %d  Threats: %d  Physical: %d  Dodges: %d\nLast: %s  Direction: %s  Contact: %d ms  Delay: %d/%d ms\nReaction: %s  Ack: %s  Projectile: %s  Plan: %d%%\nIntent: %s %d%%  Paths: %d  Tail risk: %d%%  Window: %s  Envelope: %s\nTerrain: %s  Ground vetoes: %d  Fling brakes: %d  Block: %s\nMPC: %.2f ms / %d tests  Work: %.2f ms  Gap: %.1f/%.1f ms  Deferred: %d",
        State.Enabled and "ON" or "OFF",
        dashText,
        State.WatcherCount,
        State.PendingCount,
        State.ProjectileCount,
        State.AcceptedDodges,
        State.LastThreat,
        State.LastDirection,
        State.LastContactMilliseconds,
        math.floor(State.LastActivationDelay * 1000 + 0.5),
        math.floor(State.LastMpcLatestDelay * 1000 + 0.5),
        reactionText,
        acknowledgementText,
        State.LastProjectileModel,
        math.floor(State.LastPlanConfidence * 100 + 0.5),
        State.LastIntentModel,
        math.floor(State.LastIntentConfidence * 100 + 0.5),
        State.LastPathHypotheses,
        math.floor(State.LastTailRisk * 100 + 0.5),
        impactText,
        State.LastEnvelopeComplete and "complete" or "conservative",
        State.LastTerrainStatus,
        State.TerrainRejectedDodges,
        State.FlingGuardTrips,
        State.LastBlockReason,
        State.LastMpcMilliseconds,
        State.LastMpcTests,
        State.FrameWorkMean * 1000,
        State.LastFrameGapMilliseconds,
        State.MaximumFrameGapMilliseconds,
        State.DeferredThreatEvaluations
    )
end

local function reportError(context, message)
    State.ErrorCount += 1
    State.ConsecutiveErrors += 1
    if State.ErrorCount <= 3 then
        warn("[Ink Auto Dodge] " .. context .. ": " .. tostring(message))
    end
    if State.ConsecutiveErrors >= MAX_ERRORS and State.Enabled then
        warn("[Ink Auto Dodge] Safety fuse opened after consecutive errors")
        State:SetEnabled(false)
    end
end

local function guarded(context, callback)
    return function(...)
        local ok, message = xpcall(callback, debug.traceback, ...)
        if not ok then
            reportError(context, message)
        else
            State.ConsecutiveErrors = 0
        end
    end
end

local function replayNumber(value, fallback)
    return type(value) == "number" and value == value
        and math.floor(value * 10000 + 0.5) / 10000
        or fallback or 0
end

local function pushReplay(kind, now, fields)
    local entry = {
        At = replayNumber(now),
        Kind = string.sub(tostring(kind or "event"), 1, 32),
    }
    if fields then
        for key, value in pairs(fields) do
            if type(value) == "number" then
                entry[key] = replayNumber(value)
            elseif type(value) == "boolean" then
                entry[key] = value
            elseif type(value) == "string" then
                entry[key] = string.sub(value, 1, 64)
            end
        end
    end
    local head = State.ReplayHead % MAX_REPLAY_SAMPLES + 1
    State.Replay[head] = entry
    State.ReplayHead = head
    State.ReplayCount = math.min(State.ReplayCount + 1, MAX_REPLAY_SAMPLES)
end

function State:GetReplaySnapshot(limit)
    limit = math.clamp(math.floor(tonumber(limit) or 32), 1, 64)
    local count = math.min(limit, self.ReplayCount)
    local output = table.create(count)
    local first = (self.ReplayHead - count) % MAX_REPLAY_SAMPLES + 1
    for index = 1, count do
        local source = self.Replay[(first + index - 2) % MAX_REPLAY_SAMPLES + 1]
        local copy = {}
        if source then
            for key, value in pairs(source) do
                copy[key] = value
            end
        end
        output[index] = copy
    end
    return output
end

local PROFILE_FAST_MELEE = {
    Name = "Fast melee",
    Kind = "Melee",
    ActiveStart = 0.13,
    ActiveEnd = 0.31,
    Range = 10.5,
    NearReach = 0.75,
    FarReach = 8.25,
    Radius = 1.75,
    Arc = math.rad(82),
    Facing = -0.05,
}
local PROFILE_MELEE = {
    Name = "Melee",
    Kind = "Melee",
    ActiveStart = 0.21,
    ActiveEnd = 0.43,
    Range = 12.5,
    NearReach = 0.75,
    FarReach = 9.75,
    Radius = 1.9,
    Arc = math.rad(88),
    Facing = 0.02,
}
local PROFILE_LUNGE = {
    Name = "Lunge",
    Kind = "Melee",
    ActiveStart = 0.16,
    ActiveEnd = 0.46,
    Range = 20,
    NearReach = 1,
    FarReach = 17,
    Radius = 2.15,
    Arc = math.rad(34),
    Facing = 0.12,
    MobilitySpeed = 65,
}
local PROFILE_HEAVY = {
    Name = "Heavy melee",
    Kind = "Melee",
    ActiveStart = 0.28,
    ActiveEnd = 0.58,
    Range = 21,
    NearReach = 0.5,
    FarReach = 17.5,
    Radius = 2.55,
    Arc = math.rad(105),
    Facing = 0.08,
}
local PROFILE_AREA = {
    Name = "Area attack",
    Kind = "Area",
    ActiveStart = 0.14,
    ActiveEnd = 0.48,
    Range = 18,
    Radius = 18,
    Facing = -0.35,
}
local PROFILE_THROW = {
    Name = "Thrown weapon",
    Kind = "Ranged",
    ActiveStart = 0.25,
    ActiveEnd = 0.42,
    Range = 85,
    Facing = 0.42,
    LineOfSight = true,
    ProjectileSpeed = 95,
    ProjectileRadius = 0.6,
}

local GUN_TOKENS = {
    "gun", "pistol", "revolver", "rifle", "shotgun", "sniper",
    "smg", "firearm", "bullet", "ammo", "uzi", "shoot", "reload",
}

local function hasGunToken(value)
    local lower = string.lower(tostring(value or ""))
    for _, token in ipairs(GUN_TOKENS) do
        if lower:find(token, 1, true) then
            return true
        end
    end
    return false
end

local function makeExactProfile(base, fields)
    local profile = {}
    for key, value in pairs(base) do
        profile[key] = value
    end
    for key, value in pairs(fields) do
        profile[key] = value
    end
    profile.Exact = true
    profile.CalibrationKey = profile.CalibrationKey or profile.Name
    profile.ActiveWindows = profile.ActiveWindows or {
        { profile.ActiveStart, profile.ActiveEnd },
    }
    if profile.Kind == "Ranged" then
        profile.ReleaseAt = profile.ReleaseAt or profile.ActiveStart
    end
    return profile
end

local EXACT_PROFILES = {}
local function bindExact(id, base, fields)
    local profile = makeExactProfile(base, fields)
    EXACT_PROFILES[tostring(id)] = profile
    return profile
end

-- Timelines are expressed in animation-time seconds. The live animation
-- lengths were measured in this universe, and every damaging non-gun weapon
-- animation gets its own immutable-by-convention profile instead of sharing
-- one generic timing record. Observed weapon/projectile motion supersedes the
-- analytic range and speed fallbacks whenever it is available.
bindExact("85623602463927", PROFILE_FAST_MELEE, {
    Name = "Bottle Swing 1", Weapon = "Bottle", ActiveStart = 0.12,
    ActiveEnd = 0.33, AnimationLength = 0.9833,
    WeaponParts = { "shattered", "WeaponBottle" }, WeaponRadius = 0.32,
})
bindExact("87978085217719", PROFILE_FAST_MELEE, {
    Name = "Bottle Swing 2", Weapon = "Bottle", ActiveStart = 0.12,
    ActiveEnd = 0.34, AnimationLength = 0.9833,
    WeaponParts = { "shattered", "WeaponBottle" }, WeaponRadius = 0.32,
})
bindExact("85793691404836", PROFILE_FAST_MELEE, {
    Name = "Fork Swing 1", Weapon = "Fork", ActiveStart = 0.115,
    ActiveEnd = 0.325, AnimationLength = 1,
    WeaponParts = { "Fork" }, TipAttachments = { "AT1", "AT2" },
    WeaponRadius = 0.18,
})
bindExact("86197206792061", PROFILE_FAST_MELEE, {
    Name = "Fork Swing 2", Weapon = "Fork", ActiveStart = 0.12,
    ActiveEnd = 0.335, AnimationLength = 1,
    WeaponParts = { "Fork" }, TipAttachments = { "AT1", "AT2" },
    WeaponRadius = 0.18,
})
bindExact("99157505926076", PROFILE_LUNGE, {
    Name = "Fork/Bottle Lunge", Weapon = "ForkBottle", ActiveStart = 0.145,
    ActiveEnd = 0.47, AnimationLength = 0.9833,
    WeaponParts = { "Fork", "shattered", "WeaponBottle" },
    TipAttachments = { "AT1", "AT2" }, WeaponRadius = 0.34,
})
bindExact("123072675259257", PROFILE_LUNGE, {
    Name = "Fists Lunge", Weapon = "Fists", ActiveStart = 0.145,
    ActiveEnd = 0.455, AnimationLength = 0.9833,
})
bindExact("116839849594540", PROFILE_FAST_MELEE, {
    Name = "Fists Swing 1", Weapon = "Fists", ActiveStart = 0.115,
    ActiveEnd = 0.31, AnimationLength = 0.9833,
})
bindExact("96924216250322", PROFILE_FAST_MELEE, {
    Name = "Fists Swing 2", Weapon = "Fists", ActiveStart = 0.12,
    ActiveEnd = 0.325, AnimationLength = 0.9833,
})
bindExact("130148105259587", PROFILE_LUNGE, {
    Name = "Knife Lunge", Weapon = "Knife", ActiveStart = 0.14,
    ActiveEnd = 0.455, AnimationLength = 1,
    WeaponParts = { "Knife" }, WeaponRadius = 0.3,
})
bindExact("79649041083405", PROFILE_FAST_MELEE, {
    Name = "Knife Swing 1", Weapon = "Knife", ActiveStart = 0.105,
    ActiveEnd = 0.295, AnimationLength = 0.9167,
    WeaponParts = { "Knife" }, WeaponRadius = 0.3,
})
bindExact("73242877658272", PROFILE_FAST_MELEE, {
    Name = "Knife Swing 2", Weapon = "Knife", ActiveStart = 0.11,
    ActiveEnd = 0.305, AnimationLength = 0.9167,
    WeaponParts = { "Knife" }, WeaponRadius = 0.3,
})
bindExact("121147456137931", PROFILE_LUNGE, {
    Name = "Knife Backstab", Weapon = "Knife", ActiveStart = 0.18,
    ActiveEnd = 0.52, AnimationLength = 1,
    WeaponParts = { "Knife" }, WeaponRadius = 0.3,
})
bindExact("87041753984253", PROFILE_HEAVY, {
    Name = "Metal Bat Swing", Weapon = "Bat", ActiveStart = 0.31,
    ActiveEnd = 0.49, AnimationLength = 1.3333,
    Range = 17, FarReach = 14, Radius = 2.2,
    WeaponParts = { "MetalBat", "Bat" }, WeaponRadius = 0.45,
})
bindExact("114928327045353", PROFILE_FAST_MELEE, {
    Name = "Fight Back Punch 1", Weapon = "Fists", ActiveStart = 0.13,
    ActiveEnd = 0.34, AnimationLength = 1.1017,
})
bindExact("135690448001690", PROFILE_FAST_MELEE, {
    Name = "Fight Back Punch 2", Weapon = "Fists", ActiveStart = 0.13,
    ActiveEnd = 0.35, AnimationLength = 1.1017,
})
bindExact("103355259844069", PROFILE_FAST_MELEE, {
    Name = "Fight Back Punch 3", Weapon = "Fists", ActiveStart = 0.1,
    ActiveEnd = 0.29, AnimationLength = 0.8,
})
bindExact("125906547773381", PROFILE_FAST_MELEE, {
    Name = "Fight Back Counter", Weapon = "Fists", ActiveStart = 0.16,
    ActiveEnd = 0.39, AnimationLength = 1.2167,
})
bindExact("128452090955120", PROFILE_HEAVY, {
    Name = "Pole Swing 1", Weapon = "Pole", ActiveStart = 0.285,
    ActiveEnd = 0.54, AnimationLength = 1.3333,
    Range = 22, FarReach = 19, WeaponParts = { "InkPole", "Pole" },
    WeaponRadius = 0.3,
})
bindExact("71000246338579", PROFILE_HEAVY, {
    Name = "Pole Swing 2", Weapon = "Pole", ActiveStart = 0.3,
    ActiveEnd = 0.57, AnimationLength = 1.3333,
    Range = 22, FarReach = 19, WeaponParts = { "InkPole", "Pole" },
    WeaponRadius = 0.3,
})
bindExact("90654171377736", PROFILE_HEAVY, {
    Name = "Rock Swing 1", Weapon = "Rock", ActiveStart = 0.2,
    ActiveEnd = 0.43, AnimationLength = 1,
    Range = 13, FarReach = 10, WeaponParts = { "Rock", "default" },
    WeaponRadius = 0.55,
})
bindExact("81766558426599", PROFILE_HEAVY, {
    Name = "Rock Swing 2", Weapon = "Rock", ActiveStart = 0.205,
    ActiveEnd = 0.44, AnimationLength = 0.9833,
    Range = 13, FarReach = 10, WeaponParts = { "Rock", "default" },
    WeaponRadius = 0.55,
})
bindExact("72128148665361", PROFILE_HEAVY, {
    Name = "Rock Beatdown Cast", Weapon = "Rock", ActiveStart = 0.24,
    ActiveEnd = 0.5, AnimationLength = 1,
    WeaponParts = { "Rock", "default" }, WeaponRadius = 0.6,
})
bindExact("70523299428932", PROFILE_LUNGE, {
    Name = "Rock Lunge", Weapon = "Rock", ActiveStart = 0.15,
    ActiveEnd = 0.46, AnimationLength = 1,
    WeaponParts = { "Rock", "default" }, WeaponRadius = 0.6,
})

local function bindThrow(id, name, weapon, releaseAt, animationLength, speed, radius)
    return bindExact(id, PROFILE_THROW, {
        Name = name,
        Weapon = weapon,
        ActiveStart = releaseAt,
        ActiveEnd = releaseAt + 0.12,
        ReleaseAt = releaseAt,
        AnimationLength = animationLength,
        ProjectileSpeed = speed,
        ProjectileRadius = radius,
        ProjectileSignature = string.lower(weapon),
        WeaponParts = { weapon },
    })
end

bindThrow("94215646393565", "Knife Throw", "Knife", 0.295, 1.3, 112, 0.6)
bindThrow("72557176302052", "Fork Throw", "Fork", 0.29, 1.3, 112, 0.35)
bindThrow("73150160715773", "Bottle Throw", "Bottle", 0.305, 1.3, 96, 0.65)
bindThrow("112950478995075", "Pole Throw", "Pole", 0.39, 1.75, 82, 0.45)
bindThrow("94893161147811", "Rock Throw", "Rock", 0.275, 1.1667, 88, 0.55)
bindThrow("97863204720378", "Pocket Sand", "Sand", 0.225, 0.85, 120, 1.1)
bindThrow("137824029524579", "Hardball Pitch", "Pebble", 0.27, 2, 125, 0.55)
bindThrow("93105538774923", "Boomerang Throw", "Boomerang", 0.36, 1.8, 78, 1.15)
bindThrow("108262048142532", "Grenade Throw", "Grenade", 0.31, 1.3, 68, 0.75)
bindThrow("106370995610424", "Flashbang Throw", "Flashbang", 0.31, 1.3, 68, 0.75)

bindExact("134484307969531", PROFILE_HEAVY, {
    Name = "Bulldozer Tackle", Weapon = "Body", ActiveStart = 0.08,
    ActiveEnd = 0.42, AnimationLength = 0.5833,
    TravelHitbox = true, MobilitySpeed = 140,
})
bindExact("114617637295467", PROFILE_LUNGE, {
    Name = "Takedown Startup", Weapon = "Body", ActiveStart = 0.2,
    ActiveEnd = 0.56, AnimationLength = 0.95,
    TravelHitbox = true, MobilitySpeed = 120,
})
bindExact("95623680038308", PROFILE_LUNGE, {
    Name = "Takedown", Weapon = "Body", ActiveStart = 0.12,
    ActiveEnd = 0.5, AnimationLength = 2.4833,
    TravelHitbox = true, MobilitySpeed = 120,
})
bindExact("93373403484012", PROFILE_LUNGE, {
    Name = "Umbrella Lunge", Weapon = "Umbrella", ActiveStart = 0.31,
    ActiveEnd = 0.78, AnimationLength = 2.5833,
    WeaponParts = { "Umbrella" }, WeaponRadius = 0.55,
})

local THROWABLE_ANIMATION_PROFILES = {
    ["135795445788913"] = bindThrow("135795445788913", "Salt Throw Right", "Salt", 0.22, 1, 72, 0.55),
    ["122033913024777"] = bindThrow("122033913024777", "Pepper Throw Left", "Pepper", 0.22, 1, 72, 0.55),
    ["129728840520242"] = bindThrow("129728840520242", "Plate Throw Right", "Plate", 0.225, 1, 76, 0.7),
    ["95804134907746"] = bindThrow("95804134907746", "Plate Throw Left", "Plate", 0.225, 1, 76, 0.7),
    ["140518017446591"] = bindThrow("140518017446591", "Candle Throw Right", "Candle", 0.23, 1, 72, 0.65),
    ["122935841244706"] = bindThrow("122935841244706", "Candle Throw Left", "Candle", 0.23, 1, 72, 0.65),
    ["82269186748326"] = bindThrow("82269186748326", "Glass Throw Right", "Glass", 0.22, 1, 78, 0.6),
    ["139960560779757"] = bindThrow("139960560779757", "Glass Throw Left", "Glass", 0.22, 1, 78, 0.6),
    ["123619475451718"] = bindThrow("123619475451718", "Chair Throw Right", "Chair", 0.3, 1.25, 58, 2.15),
    ["131289184915690"] = bindThrow("131289184915690", "Chair Throw Left", "Chair", 0.3, 1.25, 58, 2.15),
    ["72021092651512"] = bindThrow("72021092651512", "Lamp Throw Right", "Lamp", 0.255, 1.1, 66, 0.95),
    ["122589153488534"] = bindThrow("122589153488534", "Lamp Throw Left", "Lamp", 0.255, 1.1, 66, 0.95),
}

local PROJECTILE_SIGNATURES = {
    knife = { Name = "Knife", Radius = 0.6, TTL = 4 },
    fork = { Name = "Fork", Radius = 0.35, TTL = 4 },
    bottle = { Name = "Bottle", Radius = 0.65, TTL = 4 },
    rock = { Name = "Rock", Radius = 0.6, TTL = 4 },
    pole = { Name = "Pole", Radius = 0.45, TTL = 4 },
    boomerang = { Name = "Boomerang", Radius = 1.15, TTL = 5 },
    pebble = { Name = "Pebble", Radius = 0.55, TTL = 4 },
    salt = { Name = "Salt", Radius = 0.55, TTL = 4 },
    pepper = { Name = "Pepper", Radius = 0.55, TTL = 4 },
    plate = { Name = "Plate", Radius = 0.7, TTL = 4 },
    candle = { Name = "Candle", Radius = 0.65, TTL = 4 },
    glass = { Name = "Glass", Radius = 0.6, TTL = 4 },
    chair = { Name = "Chair", Radius = 2.15, TTL = 4 },
    lamp = { Name = "Lamp", Radius = 0.95, TTL = 4 },
    grenade = { Name = "Grenade", Radius = 0.75, TTL = 5 },
    flashbang = { Name = "Flashbang", Radius = 0.75, TTL = 5 },
    sand = { Name = "Sand", Radius = 1.1, TTL = 4 },
}

local WEAPON_PART_NAMES = {
    fork = true, knife = true, shattered = true, weaponbottle = true,
    inkpole = true, pole = true, rock = true, default = true,
    metalbat = true, bat = true, umbrella = true,
}
local function findPath(root, path)
    local object = root
    for _, name in ipairs(path) do
        object = object and object:FindFirstChild(name)
        if not object then
            return nil
        end
    end
    return object
end

local function belongsToAllowedWeapon(object, character)
    if not object or not object:IsA("BasePart") then
        return false
    end
    local lower = string.lower(object.Name)
    if not WEAPON_PART_NAMES[lower] then
        return false
    end
    local cursor = object
    while cursor and cursor ~= character do
        if cursor:IsA("Accessory") or hasGunToken(cursor.Name) then
            return false
        end
        cursor = cursor.Parent
    end
    return cursor == character
end

local function cacheWeaponPart(watcher, object)
    if not watcher or not belongsToAllowedWeapon(object, watcher.Character) then
        return false
    end
    watcher.WeaponParts = watcher.WeaponParts or setmetatable({}, { __mode = "k" })
    if watcher.WeaponParts[object] then
        return true
    end
    local count = 0
    for part in pairs(watcher.WeaponParts) do
        if part and part.Parent then
            count += 1
        end
    end
    if count >= MAX_WEAPON_PARTS then
        return false
    end
    watcher.WeaponParts[object] = true
    return true
end

local function rebuildWeaponCache(watcher)
    watcher.WeaponParts = setmetatable({}, { __mode = "k" })
    watcher.WeaponSamples = setmetatable({}, { __mode = "k" })
    -- Character scans happen only at watcher creation/recovery, never in the
    -- frame loop. Normal additions are handled incrementally below.
    local scanned = 0
    for _, object in ipairs(watcher.Character:GetDescendants()) do
        scanned += 1
        if scanned > 160 then
            break
        end
        cacheWeaponPart(watcher, object)
    end
end

local function profileWantsPart(profile, part)
    local names = profile and profile.WeaponParts
    if not names then
        return false
    end
    local lower = string.lower(part.Name)
    for _, name in ipairs(names) do
        if lower == string.lower(name) then
            return true
        end
    end
    return false
end

local function findWeaponPart(watcher, profile)
    if not watcher or not profile or not profile.WeaponParts then
        return nil
    end
    local best
    local bestDistance = math.huge
    local hand = watcher.Character:FindFirstChild("RightHand")
        or watcher.Character:FindFirstChild("Right Arm")
        or watcher.Root
    for part in pairs(watcher.WeaponParts or {}) do
        if part and part.Parent and profileWantsPart(profile, part)
            and belongsToAllowedWeapon(part, watcher.Character) then
            local distance = hand and (part.Position - hand.Position).Magnitude or 0
            if distance < bestDistance then
                best = part
                bestDistance = distance
            end
        end
    end
    return best
end

local function findLaunchSource(character, profile, watcher)
    -- Strict allowlist: never inspect FireFrom/Muzzle/MuzzleAttachment. Those
    -- names can belong to guns, whose shots are intentionally excluded.
    local weaponPart = findWeaponPart(watcher, profile)
    if weaponPart then
        return weaponPart, false
    end
    local hand = character:FindFirstChild("RightHand")
        or character:FindFirstChild("Right Arm")
    if hand and hand:IsA("BasePart") and not hasGunToken(profile and profile.Weapon) then
        return hand, false
    end
    return nil, false
end

local function readLaunchSource(source, useDirection, fallbackOrigin, fallbackDirection)
    if not source or not source.Parent then
        return fallbackOrigin, fallbackDirection
    end
    local ok, sourceCFrame = pcall(function()
        return source:IsA("Attachment") and source.WorldCFrame or source.CFrame
    end)
    if not ok then
        return fallbackOrigin, fallbackDirection
    end
    local origin = sourceCFrame.Position
    local sourceLook = sourceCFrame.LookVector
    local direction = useDirection and sourceLook.Magnitude > 0.001
        and sourceLook.Unit or fallbackDirection
    return origin, direction
end

local function buildProfiles(force)
    if State.Profiles and not force then
        return true
    end

    local profiles = {}
    local dashIds = {}
    local count = 0
    local exactCount = 0
    local animations = ReplicatedStorage:FindFirstChild("Animations")
    if not animations then
        -- Do not cache a failed early lookup. ReplicatedStorage can still be
        -- streaming when F1 is first pressed.
        State.NextProfileRefreshAt = os.clock() + 0.5
        return false
    end

    local function addId(id, profile)
        if count >= 256 or not profile then
            return false
        end
        id = normalizeAnimationId(id)
        if id and not profiles[id]
            and not hasGunToken(profile.Name)
            and not hasGunToken(profile.Weapon) then
            profiles[id] = profile
            count += 1
            return true
        end
        return false
    end

    local function add(animation, profile)
        if not animation or not animation:IsA("Animation") then
            return
        end
        if hasGunToken(animation.Name) or hasGunToken(animation:GetFullName()) then
            return
        end
        addId(animation.AnimationId, profile)
    end

    local function addExact(path, profile)
        add(findPath(animations, path), profile)
    end

    -- Exact, allowlisted non-gun bindings always win over folder fallbacks.
    -- Registering them first also reserves their slots under the hard cap.
    for id, profile in pairs(EXACT_PROFILES) do
        if addId(id, profile) then
            exactCount += 1
        end
    end

    local dashing = animations:FindFirstChild("Dashing")
    if dashing then
        for _, animation in ipairs(dashing:GetChildren()) do
            if animation:IsA("Animation") then
                local id = normalizeAnimationId(animation.AnimationId)
                if id then
                    dashIds[id] = true
                end
            end
        end
    end

    local function indexFolder(path, profileForName)
        local folder = findPath(animations, path)
        if not folder or hasGunToken(table.concat(path, "/")) then
            return
        end
        -- These are small, explicitly selected attack folders. This scan runs
        -- once on the first enable and never during frame updates.
        for _, object in ipairs(folder:GetDescendants()) do
            if object:IsA("Animation") then
                local profile = not hasGunToken(object.Name)
                    and profileForName(object.Name) or nil
                if profile then
                    add(object, profile)
                end
            end
        end
    end

    indexFolder({ "Abilities", "Fists" }, function(name)
        if name:find("Lunge") then
            return PROFILE_LUNGE
        elseif name:find("Swing") then
            return PROFILE_FAST_MELEE
        end
    end)
    indexFolder({ "Abilities", "Knife" }, function(name)
        if name:find("Victim") then
            return nil
        elseif name:find("Lunge") or name:find("Backstab") then
            return PROFILE_LUNGE
        elseif name:find("Swing") then
            return PROFILE_FAST_MELEE
        end
    end)
    indexFolder({ "Abilities", "Fork" }, function(name)
        if name:find("Victim") or name:find("Equip")
            or name:find("Pickup") or name:find("Receive")
            or name:find("Give") then
            return nil
        elseif name:find("Lunge") then
            return PROFILE_LUNGE
        elseif name:find("Swing") then
            return PROFILE_FAST_MELEE
        end
    end)
    indexFolder({ "Abilities", "FightBack" }, function(name)
        if name:find("Victim") or name:find("Equipping") then
            return nil
        elseif name:find("PoleThrow") then
            return PROFILE_THROW
        elseif name:find("PoleSwing") then
            return PROFILE_HEAVY
        elseif name:find("Punch") then
            return PROFILE_FAST_MELEE
        end
    end)
    indexFolder({ "Abilities", "Rock" }, function(name)
        if name:find("Victim") or name:find("Pickup") then
            return nil
        elseif name == "Throw" then
            return PROFILE_THROW
        elseif name == "Lunge" then
            return PROFILE_LUNGE
        elseif name:find("Swing") or name == "BeatdownCast" then
            return PROFILE_HEAVY
        end
    end)
    indexFolder({ "Abilities", "ThrowWeapon" }, function(name)
        if name:find("Victim") or name:find("Pickup") then
            return nil
        elseif name:find("Throw") then
            return PROFILE_THROW
        elseif name:find("Beatdown") then
            return PROFILE_HEAVY
        end
    end)
    -- Animations/Throwables is deliberately not indexed generically. Its
    -- current damaging objects are bound by exact ID above; future unknown
    -- fire/shoot/reload animations remain ignored instead of becoming shots.
    addExact({ "Abilities", "PocketSand", "ThrowSand" }, PROFILE_THROW)
    addExact({ "Abilities", "Bulldozer", "Tackle" }, PROFILE_HEAVY)
    addExact({ "Abilities", "Blackflash", "BlackflashStartup" }, PROFILE_AREA)
    addExact({ "Abilities", "Blackflash", "BlackflashUser" }, PROFILE_AREA)
    addExact({ "Abilities", "LightningGodGrab", "CharAnim" }, PROFILE_LUNGE)
    addExact({ "Abilities", "Takedown", "Startup" }, PROFILE_LUNGE)
    addExact({ "Abilities", "Takedown", "User" }, PROFILE_LUNGE)
    addExact({ "Abilities", "Hercules", "HerculesThrow" }, PROFILE_LUNGE)
    addExact({ "Abilities", "Push1" }, PROFILE_AREA)
    addExact({ "Abilities", "Push2" }, PROFILE_AREA)
    addExact({ "Abilities", "Trip" }, PROFILE_FAST_MELEE)

    State.Profiles = profiles
    State.DashIds = dashIds
    State.ProfileCount = count
    State.ExactProfileCount = exactCount
    State.ProfileBuiltAt = os.clock()
    State.NextProfileRefreshAt = State.ProfileBuiltAt + 1
    return count > 0
end

local ATTACK_NAME_TOKENS = {
    "swing", "lunge", "stab", "slash", "attack", "punch",
    "tackle", "slam", "strike", "beatdown", "throw",
}
local PASSIVE_NAME_TOKENS = {
    "victim", "equip", "pickup", "receive", "give", "idle",
    "walk", "run", "jump", "fall", "reload", "charge",
}

local function hasNameToken(lower, tokens)
    for _, token in ipairs(tokens) do
        if lower:find(token, 1, true) then
            return true
        end
    end
    return false
end

local function copyLearnedProfile(base, fields)
    local profile = {}
    for key, value in pairs(base) do
        profile[key] = value
    end
    for key, value in pairs(fields) do
        profile[key] = value
    end
    profile.Exact = false
    profile.Provenance = "LearnedBehavior"
    profile.ActiveWindows = {
        { profile.ActiveStart, profile.ActiveEnd },
    }
    if profile.Kind == "Ranged" then
        profile.ReleaseAt = profile.ReleaseAt or profile.ActiveStart
    end
    return profile
end

local function observeDynamicAnimation(animation, id, watcher, now)
    if not animation or not id or not watcher
        or hasGunToken(animation.Name) then
        return nil
    end
    local cached = State.DynamicProfiles[id]
    if cached then
        cached.Observations = math.min((cached.Observations or 0) + 1, 12)
        cached.Actors = cached.Actors or {}
        local actorToken = string.sub(watcher.Character.Name, 1, 48)
        if not cached.Actors[actorToken]
            and (cached.ActorCount or 0) < 3 then
            cached.Actors[actorToken] = true
            cached.ActorCount = (cached.ActorCount or 0) + 1
        end
        cached.Confidence = math.max(
            cached.Confidence or 0,
            (cached.ActorCount or 0) >= 2 and 0.88
                or cached.Observations >= 5 and 0.84
                or 0.78
        )
        return cached.Profile, cached.Confidence
    end
    local lower = string.lower(tostring(animation.Name or ""))
    if hasNameToken(lower, PASSIVE_NAME_TOKENS)
        or not hasNameToken(lower, ATTACK_NAME_TOKENS) then
        return nil
    end

    local observation = State.ShadowAnimations[id]
    if not observation then
        if State.ShadowAnimationCount >= MAX_SHADOW_ANIMATIONS then
            return nil
        end
        observation = {
            Count = 0,
            FirstAt = now,
            LastAt = now,
            Actors = {},
            ActorCount = 0,
            Name = string.sub(animation.Name, 1, 48),
        }
        State.ShadowAnimations[id] = observation
        State.ShadowAnimationCount += 1
    end
    observation.Count = math.min(observation.Count + 1, 12)
    observation.LastAt = now
    local actorToken = string.sub(watcher.Character.Name, 1, 48)
    if not observation.Actors[actorToken]
        and observation.ActorCount < 3 then
        observation.Actors[actorToken] = true
        observation.ActorCount += 1
    end
    pushReplay("unknown_seen", now, {
        Id = id,
        Name = observation.Name,
        Count = observation.Count,
    })

    local part
    for candidate in pairs(watcher.WeaponParts or {}) do
        if candidate and candidate.Parent
            and belongsToAllowedWeapon(candidate, watcher.Character) then
            part = candidate
            break
        end
    end
    local isThrow = lower:find("throw", 1, true) ~= nil
    local corroborated = part ~= nil
        and (observation.Count >= 3 or observation.ActorCount >= 2)
    if not corroborated or State.DynamicProfileCount >= MAX_DYNAMIC_ANIMATIONS then
        return nil
    end

    local base = isThrow and PROFILE_THROW
        or lower:find("lunge", 1, true) and PROFILE_LUNGE
        or lower:find("slam", 1, true) and PROFILE_HEAVY
        or PROFILE_FAST_MELEE
    local weaponName = part and part.Name or "Body"
    local profile = copyLearnedProfile(base, {
        Name = "Learned " .. string.sub(animation.Name, 1, 36),
        Weapon = weaponName,
        WeaponParts = part and { part.Name } or nil,
        ActiveStart = math.max(0.07, base.ActiveStart - 0.05),
        ActiveEnd = base.ActiveEnd + 0.08,
        ReleaseAt = isThrow and math.max(0.1, base.ActiveStart - 0.05) or nil,
        CalibrationKey = id,
        Learned = true,
    })
    local confidence = observation.ActorCount >= 2 and 0.88
        or observation.Count >= 5 and 0.84
        or 0.78
    State.DynamicProfiles[id] = {
        Profile = profile,
        Confidence = confidence,
        CreatedAt = now,
        Observations = observation.Count,
        Actors = observation.Actors,
        ActorCount = observation.ActorCount,
    }
    State.DynamicProfileCount += 1
    pushReplay("animation_promoted", now, {
        Id = id,
        Name = profile.Name,
        Confidence = confidence,
    })
    return profile, confidence
end

local function clampMagnitude(vector, maximum)
    local magnitude = vector.Magnitude
    if magnitude > maximum and magnitude > 0 then
        return vector * (maximum / magnitude)
    end
    return vector
end

local function horizontalUnit(vector, fallback)
    local flat = Vector3.new(vector.X, 0, vector.Z)
    if flat.Magnitude > 0.001 then
        return flat.Unit
    end
    return fallback or Vector3.new(0, 0, -1)
end

local function unitOrFallback(vector, fallback)
    if vector and vector.Magnitude > 0.001 then
        return vector.Unit
    end
    return fallback or Vector3.new(0, 0, -1)
end

local function rotateHorizontal(unit, radians)
    local cosine = math.cos(radians)
    local sine = math.sin(radians)
    return Vector3.new(
        unit.X * cosine - unit.Z * sine,
        0,
        unit.X * sine + unit.Z * cosine
    )
end

function State:PushMotionHistory(motion, now, position, velocity)
    local nextHead = motion.HistoryHead % self.MotionHistoryLimit + 1
    local entry = motion.History[nextHead]
    if not entry then
        entry = {}
        motion.History[nextHead] = entry
    end
    entry.At = now
    entry.Position = position
    entry.Velocity = velocity
    motion.HistoryHead = nextHead
    motion.HistoryCount = math.min(
        (motion.HistoryCount or 0) + 1,
        self.MotionHistoryLimit
    )
end

function State:SummarizeMotionIntent(motion)
    local count = motion.HistoryCount or 0
    if count < 2 then
        motion.Intent = "Continue"
        motion.IntentConfidence = 0.35
        return
    end
    local first = (motion.HistoryHead - count) % self.MotionHistoryLimit + 1
    local weightedTurn = 0
    local weightedSpeedTrend = 0
    local totalWeight = 0
    local previous
    for index = 1, count do
        local sample = motion.History[
            (first + index - 2) % self.MotionHistoryLimit + 1
        ]
        if previous and sample then
            local deltaTime = sample.At - previous.At
            local previousFlat = Vector3.new(
                previous.Velocity.X,
                0,
                previous.Velocity.Z
            )
            local currentFlat = Vector3.new(
                sample.Velocity.X,
                0,
                sample.Velocity.Z
            )
            if deltaTime >= 0.002 and deltaTime <= 0.2 then
                local weight = index / count
                if previousFlat.Magnitude > 2 and currentFlat.Magnitude > 2 then
                    local previousDirection = previousFlat.Unit
                    local currentDirection = currentFlat.Unit
                    local sine = math.clamp(
                        previousDirection:Cross(currentDirection).Y,
                        -1,
                        1
                    )
                    local cosine = math.clamp(
                        previousDirection:Dot(currentDirection),
                        -1,
                        1
                    )
                    weightedTurn += math.clamp(
                        math.atan2(sine, cosine) / deltaTime,
                        -12,
                        12
                    ) * weight
                end
                weightedSpeedTrend += math.clamp(
                    (currentFlat.Magnitude - previousFlat.Magnitude)
                        / deltaTime,
                    -700,
                    700
                ) * weight
                totalWeight += weight
            end
        end
        previous = sample
    end
    if totalWeight > 0 then
        motion.HeadingRate = weightedTurn / totalWeight
        motion.SpeedTrend = weightedSpeedTrend / totalWeight
    end
    local maneuver = math.clamp(
        math.abs(motion.HeadingRate or 0) / 5
            + math.abs(motion.SpeedTrend or 0) / 240
            + (motion.Jerk and motion.Jerk.Magnitude or 0) / 2200
            + (motion.VelocityJitter or 0) / 70,
        0,
        1
    )
    motion.ManeuverScore += (
        maneuver - (motion.ManeuverScore or 0)
    ) * 0.35
    if (motion.SpeedTrend or 0) < -45 then
        motion.Intent = "Brake"
    elseif math.abs(motion.HeadingRate or 0) > 0.9 then
        motion.Intent = motion.HeadingRate > 0 and "Turn Left" or "Turn Right"
    elseif (motion.SpeedTrend or 0) > 70 then
        motion.Intent = "Burst"
    elseif (motion.VelocityJitter or 0) > 16 then
        motion.Intent = "Strafe"
    else
        motion.Intent = "Continue"
    end
    motion.IntentConfidence = math.clamp(
        0.45 + 0.45 * motion.ManeuverScore,
        0.35,
        0.92
    )
end

local function newMotion(root, now)
    local velocity = clampMagnitude(root.AssemblyLinearVelocity, 1600)
    local motion = {
        Root = root,
        Position = root.Position,
        PreviousPosition = root.Position,
        Velocity = velocity,
        ShortVelocity = velocity,
        Acceleration = ZERO,
        PositionJitter = 0.15,
        VelocityJitter = 0,
        Jerk = ZERO,
        HeadingRate = 0,
        SpeedTrend = 0,
        ManeuverScore = 0,
        Intent = "Continue",
        IntentConfidence = 0.35,
        History = table.create(State.MotionHistoryLimit),
        HistoryHead = 0,
        HistoryCount = 0,
        SampleAt = now,
        LastChangedAt = now,
    }
    State:PushMotionHistory(motion, now, root.Position, velocity)
    return motion
end

local function sampleMotion(motion, root, now)
    if not motion or motion.Root ~= root then
        return newMotion(root, now)
    end

    local position = root.Position
    local assemblyVelocity = clampMagnitude(root.AssemblyLinearVelocity, 1600)
    local deltaTime = now - motion.SampleAt
    if deltaTime <= 0.001 then
        -- Preserve the full displacement for the next real sample instead of
        -- consuming movement with an almost-zero time denominator.
        return motion
    end

    local previousPosition = motion.Position
    local positionDelta = position - previousPosition
    local assemblyTravel = assemblyVelocity.Magnitude * deltaTime
    local uncorroboratedSnap = positionDelta.Magnitude > math.max(
        35,
        assemblyTravel * 2.5 + 12
    ) and positionDelta.Magnitude / deltaTime
        > assemblyVelocity.Magnitude + 120
    if deltaTime > 0.35 or positionDelta.Magnitude > 500
        or uncorroboratedSnap then
        motion.Position = position
        motion.PreviousPosition = position
        motion.Velocity = assemblyVelocity
        motion.ShortVelocity = assemblyVelocity
        motion.Acceleration = ZERO
        motion.PositionJitter = 0.15
        motion.VelocityJitter = 0
        motion.Jerk = ZERO
        motion.HeadingRate = 0
        motion.SpeedTrend = 0
        motion.ManeuverScore = 0
        motion.Intent = "Continue"
        motion.IntentConfidence = 0.35
        table.clear(motion.History)
        motion.HistoryHead = 0
        motion.HistoryCount = 0
        motion.SampleAt = now
        motion.LastChangedAt = now
        State:PushMotionHistory(motion, now, position, assemblyVelocity)
        return motion
    end

    local predictedPosition = previousPosition + motion.Velocity * deltaTime
    local residual = (position - predictedPosition).Magnitude
    local jitterAlpha = 1 - math.exp(-8 * deltaTime)
    motion.PositionJitter += (residual - motion.PositionJitter) * jitterAlpha

    local previousVelocity = motion.Velocity
    local targetVelocity = previousVelocity
    if positionDelta.Magnitude > 0.002 then
        local measuredVelocity = clampMagnitude(positionDelta / deltaTime, 1600)
        local disagreement = (measuredVelocity - assemblyVelocity).Magnitude
        local scale = math.max(
            12,
            0.35 * math.max(measuredVelocity.Magnitude, assemblyVelocity.Magnitude)
        )
        local agreement = math.exp(-((disagreement / scale) ^ 2))
        targetVelocity = measuredVelocity:Lerp(
            assemblyVelocity,
            0.1 + 0.35 * agreement
        )
        motion.ShortVelocity = measuredVelocity
        motion.LastChangedAt = now
    elseif now - motion.LastChangedAt > 0.12 then
        targetVelocity = assemblyVelocity
    end

    local innovation = (targetVelocity - previousVelocity).Magnitude
    local velocityAlpha = 1 - math.exp(-deltaTime / 0.045)
    if innovation > math.max(18, previousVelocity.Magnitude * 0.45) then
        velocityAlpha = math.max(velocityAlpha, 0.8)
    end
    local velocity = previousVelocity:Lerp(targetVelocity, velocityAlpha)
    local previousAcceleration = motion.Acceleration
    local rawAcceleration = clampMagnitude(
        (velocity - previousVelocity) / deltaTime,
        3000
    )
    local accelerationAlpha = 1 - math.exp(-deltaTime / 0.065)
    motion.Acceleration = motion.Acceleration:Lerp(
        rawAcceleration,
        accelerationAlpha
    )
    local rawJerk = clampMagnitude(
        (motion.Acceleration - previousAcceleration) / deltaTime,
        12000
    )
    motion.Jerk = motion.Jerk:Lerp(
        rawJerk,
        1 - math.exp(-deltaTime / 0.08)
    )
    motion.VelocityJitter += (
        innovation - motion.VelocityJitter
    ) * jitterAlpha
    motion.PreviousPosition = previousPosition
    motion.Position = position
    motion.Velocity = velocity
    motion.SampleAt = now
    State:PushMotionHistory(motion, now, position, velocity)
    State:SummarizeMotionIntent(motion)
    return motion
end

local function currentWeaponSegment(watcher, profile, part)
    if not part or not part.Parent then
        return nil
    end
    local first
    local second
    local attachmentNames = profile.TipAttachments
    if attachmentNames and #attachmentNames >= 2 then
        local firstAttachment = part:FindFirstChild(attachmentNames[1], true)
        local secondAttachment = part:FindFirstChild(attachmentNames[2], true)
        if firstAttachment and firstAttachment:IsA("Attachment")
            and secondAttachment and secondAttachment:IsA("Attachment") then
            first = firstAttachment.WorldPosition
            second = secondAttachment.WorldPosition
        end
    end

    local radius = profile.WeaponRadius
    if not first or not second or (second - first).Magnitude < 0.05 then
        local size = part.Size
        local direction
        local length
        local minorFirst
        local minorSecond
        if size.X >= size.Y and size.X >= size.Z then
            direction = part.CFrame.RightVector
            length = size.X
            minorFirst, minorSecond = size.Y, size.Z
        elseif size.Y >= size.Z then
            direction = part.CFrame.UpVector
            length = size.Y
            minorFirst, minorSecond = size.X, size.Z
        else
            direction = part.CFrame.LookVector
            length = size.Z
            minorFirst, minorSecond = size.X, size.Y
        end
        first = part.Position - direction * length * 0.5
        second = part.Position + direction * length * 0.5
        radius = radius or 0.5 * math.sqrt(
            minorFirst * minorFirst + minorSecond * minorSecond
        )
    end

    local hand = watcher.Character:FindFirstChild("RightHand")
        or watcher.Character:FindFirstChild("Right Arm")
        or watcher.Root
    local reference = hand and hand.Position or watcher.Root.Position
    local base = first
    local tip = second
    if (first - reference).Magnitude > (second - reference).Magnitude then
        base = second
        tip = first
    end
    return base, tip, math.clamp(radius or 0.3, 0.08, 2.75),
        part.CFrame, part.Size
end

local function sampleWeaponSegment(watcher, profile, now)
    local part = findWeaponPart(watcher, profile)
    if not part then
        return nil
    end
    watcher.WeaponSamples = watcher.WeaponSamples
        or setmetatable({}, { __mode = "k" })
    local previous = watcher.WeaponSamples[part]
    if previous and now - previous.At <= 0.001 then
        return previous
    end
    local base, tip, radius, partCFrame, partSize = currentWeaponSegment(
        watcher,
        profile,
        part
    )
    if not base or not tip then
        return nil
    end

    local rootVelocity = watcher.Motion and watcher.Motion.Velocity
        or watcher.Root.AssemblyLinearVelocity
    local sample = previous or {}
    local deltaTime = previous and now - previous.At or 0
    local previousCFrame = previous and previous.CFrame or partCFrame
    local previousCenter = previousCFrame.Position
    sample.PreviousBase = previous and previous.Base or base
    sample.PreviousTip = previous and previous.Tip or tip
    sample.PreviousAt = previous and previous.At or now
    sample.BaseVelocity = rootVelocity
    sample.TipVelocity = rootVelocity
    sample.CenterVelocity = rootVelocity
    if previous and deltaTime >= 0.002 and deltaTime <= 0.2
        and (base - previous.Base).Magnitude <= 80
        and (tip - previous.Tip).Magnitude <= 80 then
        local measuredBase = clampMagnitude(
            (base - previous.Base) / deltaTime,
            900
        )
        local measuredTip = clampMagnitude(
            (tip - previous.Tip) / deltaTime,
            1200
        )
        sample.BaseVelocity = measuredBase:Lerp(rootVelocity, 0.12)
        sample.TipVelocity = measuredTip:Lerp(rootVelocity, 0.08)
        sample.CenterVelocity = clampMagnitude(
            (partCFrame.Position - previousCenter) / deltaTime,
            1000
        ):Lerp(rootVelocity, 0.1)
    end
    sample.PreviousCFrame = previousCFrame
    sample.CFrame = partCFrame
    sample.Size = partSize
    sample.AngularVelocity = clampMagnitude(part.AssemblyAngularVelocity, 80)
    sample.Part = part
    sample.Base = base
    sample.Tip = tip
    sample.Radius = radius
    sample.At = now
    watcher.WeaponSamples[part] = sample
    State.LiveWeaponSamples += 1
    return sample
end

local function finiteNumber(value)
    return type(value) == "number"
        and value == value
        and value > -math.huge
        and value < math.huge
end

local function finiteVector(value)
    return typeof(value) == "Vector3"
        and finiteNumber(value.X)
        and finiteNumber(value.Y)
        and finiteNumber(value.Z)
end

local function newEstimator(defaultMean, defaultMad)
    local mean = defaultMean or 0
    local mad = defaultMad or 0
    return {
        Mean = mean,
        Mad = mad,
        Upper = mean + 2.5 * mad,
        Samples = 0,
    }
end

local function robustUpdate(estimator, sample, minimum, maximum, clip)
    if not estimator or not finiteNumber(sample) then
        return false
    end
    sample = math.clamp(sample, minimum, maximum)
    local error = math.clamp(sample - estimator.Mean, -clip, clip)
    local alpha = error > 0 and 0.24 or 0.07
    if estimator.Samples < 4 then
        alpha = 1 / (estimator.Samples + 1)
    end
    estimator.Mean += error * alpha
    estimator.Mad += (
        math.abs(error) - estimator.Mad
    ) * math.min(0.2, alpha)
    local upper = finiteNumber(estimator.Upper)
        and estimator.Upper
        or estimator.Mean + 2.5 * estimator.Mad
    local upperError = math.clamp(sample - upper, -clip, clip)
    upper += upperError * (upperError > 0 and 0.35 or 0.025)
    estimator.Upper = math.clamp(
        math.max(estimator.Mean, upper),
        minimum,
        maximum
    )
    estimator.Samples += 1
    State.CalibrationSamples += 1
    return true
end

function State:ConservativeUpper(estimator)
    if not estimator then
        return 0
    end
    return math.max(
        estimator.Mean + 2.5 * estimator.Mad,
        finiteNumber(estimator.Upper) and estimator.Upper or -math.huge
    )
end

function State:DashCalibrationKey(character, phantom)
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local grounded = humanoid
        and humanoid.FloorMaterial ~= Enum.Material.Air
        and "Ground" or "Air"
    local swingSpeed = character and character:FindFirstChild("SwingSpeed")
    local multiplier = 1
    if swingSpeed then
        local ok, value = pcall(function()
            return swingSpeed.Value
        end)
        if ok and type(value) == "number" then
            multiplier = value
        end
    end
    multiplier = math.floor(math.clamp(multiplier, 0.25, 4) * 20 + 0.5) / 20
    local sprintTier = 0
    if phantom then
        local boosts = LocalPlayer:FindFirstChild("Boosts")
        local fasterSprint = boosts and boosts:FindFirstChild("Faster Sprint")
        if fasterSprint then
            local ok, value = pcall(function()
                return fasterSprint.Value
            end)
            if ok and type(value) == "number" then
                sprintTier = math.clamp(
                    math.floor(value / 1.5 + 0.5),
                    0,
                    5
                )
            end
        end
    end
    return string.format(
        "%s|%s|%d|%.2f",
        phantom and "Phantom" or "Normal",
        grounded,
        sprintTier,
        multiplier
    )
end

function State:CurrentDashCalibrationKey(character, phantom)
    local now = os.clock()
    if State.DashCalibrationKeyCharacter ~= character
        or State.DashCalibrationKeyPhantom ~= phantom
        or now >= State.DashCalibrationKeyExpiresAt
        or not State.DashCalibrationKeyValue then
        State.DashCalibrationKeyCharacter = character
        State.DashCalibrationKeyPhantom = phantom
        State.DashCalibrationKeyValue = self:DashCalibrationKey(
            character,
            phantom
        )
        State.DashCalibrationKeyExpiresAt = now + 0.2
    end
    return State.DashCalibrationKeyValue
end

function State:CalibratedDashDistance(key, timeAhead, analyticDistance)
    local curve = State.DashCurveCalibration[key]
    if not curve then
        return analyticDistance
    end
    local lower = curve.Lower
    if not lower then
        lower = table.create(#self.DashCurveSampleTimes)
        curve.Lower = lower
        curve.Dirty = true
    end
    if curve.Dirty then
        table.clear(lower)
        local running = 0
        local valid = 0
        for index = 1, #self.DashCurveSampleTimes do
            local estimator = curve[index]
            if estimator and estimator.Samples >= 3 then
                running = math.max(
                    running,
                    math.max(0, estimator.Mean - 2.5 * estimator.Mad)
                )
                lower[index] = running
                valid += 1
            end
        end
        curve.ValidCount = valid
        curve.Dirty = false
    end
    if (curve.ValidCount or 0) == 0 then
        return analyticDistance
    end
    local learned
    local previousTime = 0
    local previousDistance = 0
    for index, sampleTime in ipairs(self.DashCurveSampleTimes) do
        local distance = lower[index]
        if distance then
            if timeAhead <= sampleTime then
                local alpha = math.clamp(
                    (timeAhead - previousTime)
                        / math.max(sampleTime - previousTime, 0.001),
                    0,
                    1
                )
                learned = previousDistance
                    + (distance - previousDistance) * alpha
                break
            end
            previousTime = sampleTime
            previousDistance = distance
            learned = distance
        end
    end
    return math.min(analyticDistance, learned or analyticDistance)
end

-- Threat avoidance intentionally uses the learned lower reach envelope above:
-- it must not assume that a dash will carry the character farther than it can.
-- Terrain validation has the opposite requirement.  It must cover the farthest
-- credible endpoint so a fast Phantom Step cannot outrun the floor probes.
function State:CalibratedDashUpperDistance(key, timeAhead, analyticDistance)
    local curve = State.DashCurveCalibration[key]
    if not curve then
        return analyticDistance
    end
    local learned
    local previousTime = 0
    local previousDistance = 0
    local running = 0
    for index, sampleTime in ipairs(self.DashCurveSampleTimes) do
        local estimator = curve[index]
        if estimator and estimator.Samples >= 3 then
            local upper = finiteNumber(estimator.Upper)
                and estimator.Upper
                or estimator.Mean + 2.5 * estimator.Mad
            running = math.max(running, math.clamp(upper, 0, 180))
            if timeAhead <= sampleTime then
                local alpha = math.clamp(
                    (timeAhead - previousTime)
                        / math.max(sampleTime - previousTime, 0.001),
                    0,
                    1
                )
                learned = previousDistance
                    + (running - previousDistance) * alpha
                break
            end
            previousTime = sampleTime
            previousDistance = running
            learned = running
        end
    end
    return math.max(analyticDistance, learned or analyticDistance)
end

function State:BeginDashTelemetry(
    character,
    root,
    direction,
    requestedAt,
    baselineVelocity,
    phantom
)
    if #State.DashTelemetry >= self.MaxDashTelemetry then
        table.remove(State.DashTelemetry, 1)
        State.DashCalibrationRejects += 1
    end
    local record = {
        Character = character,
        Root = root,
        Direction = horizontalUnit(direction),
        RequestedAt = requestedAt,
        StartPosition = root.Position,
        -- Phantom Step overwrites AssemblyLinearVelocity and explicitly
        -- zeroes it after 0.05 seconds.  Extending the pre-dash velocity for
        -- half a second made opposite-direction movement look like a 30+
        -- stud dash and eventually vetoed every route on compact platforms.
        BaselineVelocity = phantom and ZERO or baselineVelocity,
        Phantom = phantom == true,
        Key = self:CurrentDashCalibrationKey(character, phantom),
        NextKnot = 1,
        Samples = table.create(#self.DashCurveSampleTimes),
        PreviousAt = requestedAt,
        PreviousPosition = root.Position,
        Accepted = false,
        Rejected = false,
    }
    State.DashTelemetry[#State.DashTelemetry + 1] = record
    return record
end

function State:CommitDashTelemetry(record)
    -- Phantom Step has an exact deterministic controller formula and a hard
    -- 0.05-second stop.  Later position samples contain normal walking and
    -- collisions, so they must never replace that exact travel envelope.
    if record.Phantom then
        return
    end
    local curve = State.DashCurveCalibration[record.Key]
    if not curve then
        curve = {}
        State.DashCurveCalibration[record.Key] = curve
    end
    for index, sample in ipairs(record.Samples) do
        if sample and sample.Clean then
            local estimator = curve[index]
            if not estimator then
                estimator = newEstimator(sample.Distance, 0.5)
                curve[index] = estimator
            end
            if robustUpdate(estimator, sample.Distance, 0, 180, 30) then
                State.DashCalibrationSamples += 1
                curve.Dirty = true
            end
        end
    end
end

function State:SampleDashTelemetry(now)
    for index = #State.DashTelemetry, 1, -1 do
        local record = State.DashTelemetry[index]
        local root = record.Root
        local elapsed = now - record.RequestedAt
        if not root or not root.Parent
            or LocalPlayer.Character ~= record.Character then
            record.Rejected = true
        else
            local previousElapsed = math.max(
                0,
                record.PreviousAt - record.RequestedAt
            )
            local interval = math.max(now - record.PreviousAt, 0.0001)
            while record.NextKnot <= #self.DashCurveSampleTimes do
                local knot = self.DashCurveSampleTimes[record.NextKnot]
                if knot > elapsed + 0.0005 then
                    break
                end
                local alpha = math.clamp(
                    (knot - previousElapsed) / interval,
                    0,
                    1
                )
                local position = record.PreviousPosition:Lerp(
                    root.Position,
                    alpha
                )
                local baseline = record.StartPosition
                    + record.BaselineVelocity * knot
                local excess = position - baseline
                local horizontal = Vector3.new(excess.X, 0, excess.Z)
                local distance = horizontal:Dot(record.Direction)
                local lateral = (
                    horizontal - record.Direction * distance
                ).Magnitude
                record.Samples[record.NextKnot] = {
                    Distance = math.max(0, distance),
                    Clean = distance >= 0
                        and distance <= 180
                        and lateral <= math.max(4, distance * 0.75),
                }
                record.NextKnot += 1
            end
            record.PreviousAt = now
            record.PreviousPosition = root.Position
        end
        local complete = record.NextKnot > #self.DashCurveSampleTimes
            or elapsed > self.DashCurveSampleTimes[
                #self.DashCurveSampleTimes
            ] + 0.08
        if record.Rejected or complete then
            if record.Accepted and not record.Rejected then
                self:CommitDashTelemetry(record)
            else
                State.DashCalibrationRejects += 1
            end
            table.remove(State.DashTelemetry, index)
        end
    end
end

local function calibrationFor(profile, timingKey)
    local key = tostring(timingKey
        or profile and profile.CalibrationKey
        or "Generic")
    local calibration = State.CalibrationByKey[key]
    if not calibration then
        calibration = {
            Callback = newEstimator(0.01, 0.005),
            StartEarly = newEstimator(0, 0.012),
            EndLate = newEstimator(0, 0.012),
            ReleaseEarly = newEstimator(0, 0.012),
            ReplicationPhase = newEstimator(0, 0.004),
        }
        State.CalibrationByKey[key] = calibration
    end
    return calibration
end

local function effectiveTiming(profile, timingKey)
    local calibration = calibrationFor(profile, timingKey)
    local startEarly = calibration.StartEarly.Samples >= 2
        and math.clamp(
            State:ConservativeUpper(calibration.StartEarly),
            0,
            0.12
        ) or 0
    local endLate = calibration.EndLate.Samples >= 2
        and math.clamp(
            State:ConservativeUpper(calibration.EndLate),
            0,
            0.12
        ) or 0
    local releaseEarly = calibration.ReleaseEarly.Samples >= 2
        and math.clamp(
            State:ConservativeUpper(calibration.ReleaseEarly),
            0,
            0.12
        ) or 0
    -- Learning can only widen the defensive envelope. A delayed replicated
    -- sample can never teach the system to react later than the static table.
    return profile.ActiveStart - startEarly,
        profile.ActiveEnd + endLate,
        (profile.ReleaseAt or profile.ActiveStart) - releaseEarly
end

local function updateTiming(deltaTime, now)
    local rawFrame = math.clamp(deltaTime or State.FrameMean, 1 / 300, 0.25)
    State.LastFrameGapMilliseconds = rawFrame * 1000
    State.MaximumFrameGapMilliseconds = math.max(
        State.MaximumFrameGapMilliseconds,
        State.LastFrameGapMilliseconds
    )
    -- Isolated scheduler/GC stalls belong in gap telemetry, not in the
    -- predictor's reaction lead or Phantom cooldown.  Winsorizing the mean
    -- prevents one hitch from making the next several dodges early and slow.
    local frame = math.clamp(rawFrame, 1 / 300, 1 / 30)
    local alpha = 1 - math.exp(-5 * frame)
    local difference = math.abs(frame - State.FrameMean)
    State.FrameMean += (frame - State.FrameMean) * alpha
    State.FrameDeviation += (difference - State.FrameDeviation) * alpha
    State.DecayingWorstFrame = math.max(
        math.min(rawFrame, 0.05),
        State.DecayingWorstFrame * math.exp(-1.5 * frame)
    )

    if now >= State.NextPingSampleAt then
        State.NextPingSampleAt = now + PING_SAMPLE_INTERVAL
        local ok, ping = pcall(LocalPlayer.GetNetworkPing, LocalPlayer)
        if ok and type(ping) == "number" then
            ping = math.clamp(ping, 0, 0.5)
            local error = math.clamp(ping - State.PingMean, -0.12, 0.12)
            local pingAlpha = error > 0 and 0.25 or 0.07
            State.PingMean += error * pingAlpha
            State.PingDeviation += (
                math.abs(error) - State.PingDeviation
            ) * 0.14
        end
    end

    if now >= State.NextServerClockSampleAt then
        State.NextServerClockSampleAt = now + PING_SAMPLE_INTERVAL
        local ok, serverNow = pcall(workspace.GetServerTimeNow, workspace)
        if ok and finiteNumber(serverNow) then
            local offset = serverNow - now
            if State.ServerClockSamples == 0
                or math.abs(offset - State.ServerClockOffset) > 0.2 then
                State.ServerClockOffset = offset
                State.ServerClockDeviation = 0
                State.ServerClockSamples = 1
                pushReplay("clock_sync", now, { Offset = offset })
            else
                local residual = offset - State.ServerClockOffset
                State.ServerClockOffset += math.clamp(
                    residual,
                    -0.02,
                    0.02
                ) * 0.12
                State.ServerClockDeviation += (
                    math.abs(residual) - State.ServerClockDeviation
                ) * 0.14
                State.ServerClockSamples = math.min(
                    State.ServerClockSamples + 1,
                    1000000
                )
            end
        end
    end
end

local function getPredictionLead(profile, timingKey)
    local calibration = calibrationFor(profile, timingKey)
    local weaponJitter = math.min(
        0.045,
        2.5 * calibration.Callback.Mad
            + 2.5 * calibration.ReleaseEarly.Mad
            + 1.5 * math.max(
                calibration.StartEarly.Mad,
                calibration.EndLate.Mad
            )
            + calibration.ReplicationPhase.Mad
    )
    return math.clamp(
        State.PingMean
            + 2.5 * State.PingDeviation
            + math.min(State.ServerClockDeviation, 0.02)
            + math.max(State.FrameMean, State.DecayingWorstFrame)
            + State.DashStartupMean
            + 2.5 * State.DashStartupDeviation
            + weaponJitter
            + 0.01,
        0.055,
        0.34
    )
end

function State:ContactIntervalFor(threat, contactTime)
    if type(contactTime) ~= "number" or contactTime ~= contactTime
        or contactTime <= -math.huge or contactTime >= math.huge then
        return nil, nil
    end
    local calibration = calibrationFor(
        threat.Profile,
        threat.TimingKey
    )
    local timingSpread = math.max(
        calibration.StartEarly.Mad or 0,
        calibration.EndLate.Mad or 0,
        calibration.ReleaseEarly.Mad or 0,
        calibration.ReplicationPhase.Mad or 0
    )
    local frameSpread = State.FrameMean + 2 * State.FrameDeviation
    local closing = math.max(
        math.abs(threat.ClosingSpeed or 0),
        math.abs(threat.AttackerApproachSpeed or 0),
        24
    )
    local spatialSpread = math.min(
        0.055,
        (threat.Uncertainty or 0.75) / closing
    )
    local before = math.clamp(
        0.45 * frameSpread + 2 * timingSpread + spatialSpread,
        0.006,
        0.11
    )
    local after = math.clamp(
        frameSpread + 2.5 * timingSpread + 1.25 * spatialSpread,
        0.01,
        0.14
    )
    return math.max(0, contactTime - before),
        math.min(MAX_PREDICTION_TIME, contactTime + after)
end

local function sphereEntry(relativePosition, relativeVelocity, radius, startTime, endTime)
    local a = relativeVelocity:Dot(relativeVelocity)
    local b = 2 * relativePosition:Dot(relativeVelocity)
    local c = relativePosition:Dot(relativePosition) - radius * radius
    if a < 0.000001 then
        return c <= 0 and startTime or nil
    end
    local discriminant = b * b - 4 * a * c
    if discriminant < 0 then
        return nil
    end
    local root = math.sqrt(discriminant)
    local enter = (-b - root) / (2 * a)
    local leave = (-b + root) / (2 * a)
    if leave < startTime or enter > endTime then
        return nil
    end
    return math.max(startTime, enter)
end

local function movingPointCapsuleEntry(
    relativePosition,
    relativeVelocity,
    halfHeight,
    radius,
    startTime,
    endTime
)
    if endTime < startTime then
        return nil
    end

    local breaks = { startTime, endTime }
    if math.abs(relativeVelocity.Y) > 0.000001 then
        local upper = (halfHeight - relativePosition.Y) / relativeVelocity.Y
        local lower = (-halfHeight - relativePosition.Y) / relativeVelocity.Y
        if upper > startTime and upper < endTime then
            breaks[#breaks + 1] = upper
        end
        if lower > startTime and lower < endTime then
            breaks[#breaks + 1] = lower
        end
    end
    table.sort(breaks)

    local earliest
    for index = 1, #breaks - 1 do
        local intervalStart = breaks[index]
        local intervalEnd = breaks[index + 1]
        local middle = (intervalStart + intervalEnd) * 0.5
        local middleY = relativePosition.Y + relativeVelocity.Y * middle
        local offset
        local velocity
        if middleY > halfHeight then
            offset = Vector3.new(
                relativePosition.X,
                relativePosition.Y - halfHeight,
                relativePosition.Z
            )
            velocity = relativeVelocity
        elseif middleY < -halfHeight then
            offset = Vector3.new(
                relativePosition.X,
                relativePosition.Y + halfHeight,
                relativePosition.Z
            )
            velocity = relativeVelocity
        else
            offset = Vector3.new(
                relativePosition.X,
                0,
                relativePosition.Z
            )
            velocity = Vector3.new(
                relativeVelocity.X,
                0,
                relativeVelocity.Z
            )
        end
        local entry = sphereEntry(
            offset,
            velocity,
            radius,
            intervalStart,
            intervalEnd
        )
        if entry and (not earliest or entry < earliest) then
            earliest = entry
        end
    end
    return earliest
end

local function segmentDistanceSquared(firstStart, firstEnd, secondStart, secondEnd)
    local firstDirection = firstEnd - firstStart
    local secondDirection = secondEnd - secondStart
    local between = firstStart - secondStart
    local firstLength = firstDirection:Dot(firstDirection)
    local secondLength = secondDirection:Dot(secondDirection)
    local projection = secondDirection:Dot(between)
    local firstParameter
    local secondParameter

    if firstLength <= 0.000001 and secondLength <= 0.000001 then
        return between:Dot(between)
    elseif firstLength <= 0.000001 then
        firstParameter = 0
        secondParameter = math.clamp(projection / secondLength, 0, 1)
    else
        local firstProjection = firstDirection:Dot(between)
        if secondLength <= 0.000001 then
            secondParameter = 0
            firstParameter = math.clamp(-firstProjection / firstLength, 0, 1)
        else
            local crossProjection = firstDirection:Dot(secondDirection)
            local denominator = firstLength * secondLength
                - crossProjection * crossProjection
            firstParameter = denominator ~= 0
                and math.clamp(
                    (crossProjection * projection - firstProjection * secondLength)
                        / denominator,
                    0,
                    1
                )
                or 0
            secondParameter = (
                crossProjection * firstParameter + projection
            ) / secondLength
            if secondParameter < 0 then
                secondParameter = 0
                firstParameter = math.clamp(-firstProjection / firstLength, 0, 1)
            elseif secondParameter > 1 then
                secondParameter = 1
                firstParameter = math.clamp(
                    (crossProjection - firstProjection) / firstLength,
                    0,
                    1
                )
            end
        end
    end

    local separation = between
        + firstDirection * firstParameter
        - secondDirection * secondParameter
    return separation:Dot(separation)
end

local function predictionVelocity(motion, preferShort)
    local velocity = motion.Velocity
    if preferShort and motion.ShortVelocity
        and motion.SampleAt - motion.LastChangedAt <= 0.12 then
        velocity = velocity:Lerp(motion.ShortVelocity, 0.75)
    end
    return velocity
end

local function predictPosition(motion, timeAhead, withAcceleration, preferShort)
    local position = motion.Position
        + predictionVelocity(motion, preferShort) * timeAhead
    if withAcceleration then
        -- Exponentially decaying acceleration keeps the velocity gained by a
        -- dash without projecting one noisy sample forever.
        local decayTime = 0.07
        local decay = math.exp(-timeAhead / decayTime)
        local displacementScale = decayTime * (
            timeAhead - decayTime * (1 - decay)
        )
        position += clampMagnitude(motion.Acceleration, 1200)
            * displacementScale
    end
    return position
end

local function predictVelocity(motion, timeAhead, withAcceleration, preferShort)
    local velocity = predictionVelocity(motion, preferShort)
    if withAcceleration and timeAhead > 0 then
        local decayTime = 0.07
        velocity += clampMagnitude(motion.Acceleration, 1200)
            * decayTime * (1 - math.exp(-timeAhead / decayTime))
    end
    return velocity
end

local function weaponSegmentAt(threat, timeAhead, attackerMotion, hypothesisOffset)
    local sample = threat.WeaponSample
    if not sample or not sample.Part or not sample.Part.Parent
        or not finiteVector(sample.Base) or not finiteVector(sample.Tip)
        or timeAhead > WEAPON_SAMPLE_HORIZON then
        return nil
    end
    local rootDelta = predictPosition(
        attackerMotion,
        timeAhead,
        true,
        threat.DashAttack
    ) - attackerMotion.Position + (hypothesisOffset or ZERO)
    local rootVelocity = predictionVelocity(attackerMotion, threat.DashAttack)
    local decayTime = 0.065
    local residualScale = decayTime * (1 - math.exp(-timeAhead / decayTime))
    local baseResidual = clampMagnitude(
        sample.BaseVelocity - rootVelocity,
        700
    )
    local tipResidual = clampMagnitude(
        sample.TipVelocity - rootVelocity,
        950
    )
    return sample.Base + rootDelta + baseResidual * residualScale,
        sample.Tip + rootDelta + tipResidual * residualScale,
        sample.Radius
end

local function rotateAroundAxis(vector, axis, angle)
    if not axis or axis.Magnitude < 0.001 or math.abs(angle) < 0.0001 then
        return vector
    end
    axis = axis.Unit
    local cosine = math.cos(angle)
    local sine = math.sin(angle)
    return vector * cosine
        + axis:Cross(vector) * sine
        + axis * axis:Dot(vector) * (1 - cosine)
end

local function weaponObbSegmentAt(
    threat,
    timeAhead,
    attackerMotion,
    hypothesisOffset
)
    local sample = threat.WeaponSample
    if not sample or not sample.CFrame or not sample.Size
        or timeAhead > WEAPON_SAMPLE_HORIZON then
        return nil
    end
    local rootDelta = predictPosition(
        attackerMotion,
        timeAhead,
        true,
        threat.DashAttack
    ) - attackerMotion.Position + (hypothesisOffset or ZERO)
    local rootVelocity = predictionVelocity(attackerMotion, threat.DashAttack)
    local decayTime = 0.065
    local residualScale = decayTime * (1 - math.exp(-timeAhead / decayTime))
    local center = sample.CFrame.Position + rootDelta
        + clampMagnitude(sample.CenterVelocity - rootVelocity, 800)
            * residualScale
    local angularVelocity = sample.AngularVelocity or ZERO
    local angularSpeed = math.min(angularVelocity.Magnitude, 80)
    local angularAxis = angularSpeed > 0.001 and angularVelocity.Unit
        or Vector3.new(0, 1, 0)
    local size = sample.Size
    local direction
    local length
    local minorFirst
    local minorSecond
    if size.X >= size.Y and size.X >= size.Z then
        direction = sample.CFrame.RightVector
        length = size.X
        minorFirst, minorSecond = size.Y, size.Z
    elseif size.Y >= size.Z then
        direction = sample.CFrame.UpVector
        length = size.Y
        minorFirst, minorSecond = size.X, size.Z
    else
        direction = sample.CFrame.LookVector
        length = size.Z
        minorFirst, minorSecond = size.X, size.Y
    end
    direction = rotateAroundAxis(
        direction,
        angularAxis,
        angularSpeed * timeAhead
    )
    local half = direction * length * 0.5
    local radius = 0.5 * math.sqrt(
        minorFirst * minorFirst + minorSecond * minorSecond
    )
    return center - half,
        center + half,
        math.clamp(math.max(sample.Radius, radius), 0.08, 2.75)
end

local function segmentCapsuleClearance(base, tip, bodyCenter, radius)
    local bodyStart = bodyCenter - Vector3.new(0, BODY_HALF_HEIGHT, 0)
    local bodyEnd = bodyCenter + Vector3.new(0, BODY_HALF_HEIGHT, 0)
    return math.sqrt(math.max(0, segmentDistanceSquared(
        base,
        tip,
        bodyStart,
        bodyEnd
    ))) - radius
end

local function sweptMovingSegmentCapsuleEntry(
    baseStart,
    tipStart,
    baseEnd,
    tipEnd,
    bodyStart,
    bodyEnd,
    radius,
    duration
)
    if duration < 0 or not finiteVector(baseStart) or not finiteVector(tipStart)
        or not finiteVector(baseEnd) or not finiteVector(tipEnd)
        or not finiteVector(bodyStart) or not finiteVector(bodyEnd) then
        return nil, math.huge
    end
    local bladeLength = math.max(
        (tipStart - baseStart).Magnitude,
        (tipEnd - baseEnd).Magnitude
    )
    local pointCount = 5
    local coveragePadding = bladeLength / (2 * (pointCount - 1))
    local expandedRadius = radius + coveragePadding
    local earliest
    local minimumClearance = math.huge
    for index = 0, pointCount - 1 do
        local fraction = index / (pointCount - 1)
        local pointStart = baseStart:Lerp(tipStart, fraction)
        local pointEnd = baseEnd:Lerp(tipEnd, fraction)
        local relativeStart = pointStart - bodyStart
        local relativeVelocity = duration > 0.000001
            and (pointEnd - pointStart - bodyEnd + bodyStart) / duration
            or ZERO
        local entry = movingPointCapsuleEntry(
            relativeStart,
            relativeVelocity,
            BODY_HALF_HEIGHT,
            expandedRadius,
            0,
            duration
        )
        if entry and (not earliest or entry < earliest) then
            earliest = entry
        end
        minimumClearance = math.min(
            minimumClearance,
            segmentCapsuleClearance(
                pointStart,
                pointStart,
                bodyStart,
                expandedRadius
            ),
            segmentCapsuleClearance(
                pointEnd,
                pointEnd,
                bodyEnd,
                expandedRadius
            )
        )
    end
    return earliest, minimumClearance
end

local function weaponContactTime(
    threat,
    localMotion,
    attackerMotion,
    startTime,
    endTime,
    uncertainty,
    bodyPositionAt
)
    local sample = threat.WeaponSample
    if not sample or endTime < startTime then
        return nil
    end
    local duration = endTime - startTime
    local relativeSpeed = math.max(
        (sample.TipVelocity - localMotion.Velocity).Magnitude,
        (sample.BaseVelocity - localMotion.Velocity).Magnitude
    )
    local stepWidth = math.max(
        BODY_RADIUS + sample.Radius + uncertainty,
        0.75
    )
    local steps = math.clamp(math.ceil(
        math.max(duration / 0.035, relativeSpeed * duration / stepWidth)
    ), 4, 14)
    if duration <= 0.000001 then
        steps = 1
    end

    local previousTime = startTime
    local previousBase, previousTip = weaponSegmentAt(
        threat,
        previousTime,
        attackerMotion
    )
    if not previousBase then
        return nil
    end
    local previousObbBase, previousObbTip, previousObbRadius =
        weaponObbSegmentAt(threat, previousTime, attackerMotion)
    local previousBody = bodyPositionAt and bodyPositionAt(previousTime)
        or predictPosition(localMotion, previousTime, true)
    for index = 1, steps do
        local sampleTime = startTime + duration * index / steps
        local base, tip = weaponSegmentAt(threat, sampleTime, attackerMotion)
        if not base then
            break
        end
        local body = bodyPositionAt and bodyPositionAt(sampleTime)
            or predictPosition(localMotion, sampleTime, true)
        local slab = sampleTime - previousTime
        local firstDirection = unitOrFallback(previousTip - previousBase)
        local secondDirection = unitOrFallback(tip - base, firstDirection)
        local cosine = math.clamp(firstDirection:Dot(secondDirection), -1, 1)
        local cosineHalf = math.sqrt(math.max(0, (1 + cosine) * 0.5))
        local rotationalPadding = math.max(
            (previousTip - previousBase).Magnitude,
            (tip - base).Magnitude
        ) * (1 - cosineHalf)
        local accelerationPadding = math.min(
            2,
            (localMotion.Acceleration.Magnitude
                + attackerMotion.Acceleration.Magnitude) * slab * slab / 8
        )
        local entry = sweptMovingSegmentCapsuleEntry(
            previousBase,
            previousTip,
            base,
            tip,
            previousBody,
            body,
            BODY_RADIUS + sample.Radius + uncertainty
                + rotationalPadding + accelerationPadding,
            slab
        )
        if entry then
            return previousTime + entry
        end
        local obbBase, obbTip, obbRadius = weaponObbSegmentAt(
            threat,
            sampleTime,
            attackerMotion
        )
        if previousObbBase and obbBase then
            local obbEntry = sweptMovingSegmentCapsuleEntry(
                previousObbBase,
                previousObbTip,
                obbBase,
                obbTip,
                previousBody,
                body,
                BODY_RADIUS + math.max(
                    previousObbRadius or 0,
                    obbRadius or 0
                ) + uncertainty + accelerationPadding,
                slab
            )
            if obbEntry then
                return previousTime + obbEntry
            end
        end
        previousTime = sampleTime
        previousBase = base
        previousTip = tip
        previousObbBase = obbBase
        previousObbTip = obbTip
        previousObbRadius = obbRadius
        previousBody = body
    end
    return nil
end

local function hasLineOfSightBetween(
    attackerCharacter,
    localCharacter,
    origin,
    target
)
    local filter = { attackerCharacter, localCharacter }
    local effects = workspace:FindFirstChild("Effects")
    if effects then
        filter[#filter + 1] = effects
    end
    local parameters = RaycastParams.new()
    parameters.FilterType = Enum.RaycastFilterType.Exclude
    parameters.FilterDescendantsInstances = filter
    parameters.IgnoreWater = true
    parameters.RespectCanCollide = true
    return workspace:Raycast(origin, target - origin, parameters) == nil
end

local function effectiveShotRange(
    attackerCharacter,
    localCharacter,
    origin,
    direction,
    maximumRange
)
    local filter = { attackerCharacter, localCharacter }
    local effects = workspace:FindFirstChild("Effects")
    if effects then
        filter[#filter + 1] = effects
    end
    local parameters = RaycastParams.new()
    parameters.FilterType = Enum.RaycastFilterType.Exclude
    parameters.FilterDescendantsInstances = filter
    parameters.IgnoreWater = true
    parameters.RespectCanCollide = true
    local result = workspace:Raycast(
        origin,
        unitOrFallback(direction) * maximumRange,
        parameters
    )
    return result and math.max(0, result.Distance - 0.05) or maximumRange
end

local function updateThreatClock(threat, now)
    local elapsedSinceSample = math.max(0, now - threat.LastPhaseAt)
    local speed = threat.PlaybackSpeed
    local elapsed = threat.LogicalElapsed + elapsedSinceSample * speed
    local track = threat.Track
    if track and track.IsPlaying then
        speed = math.max(math.abs(track.Speed), 0.05)
        elapsed = math.max(track.TimePosition, 0)
    end
    threat.PlaybackSpeed = speed
    threat.LogicalElapsed = elapsed
    threat.LastPhaseAt = now

    local profile = threat.Profile
    local effectiveStart, effectiveEnd, effectiveRelease = effectiveTiming(
        profile,
        threat.TimingKey
    )
    local untilActive = (effectiveStart - elapsed) / speed
    local untilFinished = (effectiveEnd - elapsed) / speed
    return math.max(0, untilActive), math.max(0, untilFinished), elapsed,
        effectiveStart, effectiveEnd, effectiveRelease
end

local function uncertaintyFor(profile, localMotion, attackerMotion, horizon)
    local relativeSpeed = (
        localMotion.Velocity - attackerMotion.Velocity
    ).Magnitude
    local positionNoise = localMotion.PositionJitter
        + attackerMotion.PositionJitter
    local velocityNoise = localMotion.VelocityJitter
        + attackerMotion.VelocityJitter
    local frameWindow = State.FrameMean + 2 * State.FrameDeviation
    local uncertainty = 0.55
        + 1.8 * positionNoise
        + 0.3 * velocityNoise * math.min(horizon, 0.35)
        + 0.35 * relativeSpeed * frameWindow
    local maximum = profile.Kind == "Ranged" and 4
        or profile.Kind == "Area" and 2.5
        or 6
    return math.clamp(uncertainty, 0.55, maximum)
end

local function analyticThreatRelevant(
    profile,
    distance,
    targetDirection,
    lookDirection,
    closingSpeed,
    attackerApproachSpeed,
    attackerApproachAcceleration,
    activeHorizon,
    uncertainty,
    dashAttack,
    attackerAlignment,
    hasWeaponSample
)
    if profile.Kind == "Ranged" then
        return true, "trajectory"
    end

    local baseReach = math.max(
        profile.Range or 0,
        profile.FarReach or 0,
        profile.Radius or 0
    ) + BODY_RADIUS + math.min(uncertainty or 0.75, 3) + QUEUE_MARGIN
    local horizon = math.clamp(activeHorizon or 0, 0, MAX_PREDICTION_TIME)
    local approach = math.max(
        closingSpeed or 0,
        attackerApproachSpeed or 0,
        profile.MobilitySpeed or 0,
        0
    )
    if dashAttack then
        approach = math.max(approach, 140)
    end
    approach = math.min(approach, 220)
    local acceleration = math.clamp(
        math.max(attackerApproachAcceleration or 0, 0),
        0,
        dashAttack and 320 or 110
    )
    local reachable = baseReach + approach * horizon
        + 0.5 * acceleration * horizon * horizon
    if distance > reachable then
        return false, "out of reach"
    end
    if profile.Kind == "Area" or hasWeaponSample then
        return true, profile.Kind == "Area" and "area" or "weapon"
    end

    -- Far analytic melee must be pointed into its actual swing arc.  Limit
    -- angular uncertainty independently from collision uncertainty so noisy
    -- motion cannot turn a side/back-facing swing into a 360-degree threat.
    local directionalPadding = BODY_RADIUS + (profile.Radius or 0)
        + math.min(uncertainty or 0.75, 1.5)
    if distance <= math.max(profile.NearReach or 0, 0)
        + directionalPadding then
        return true, "close overlap"
    end
    local halfArc = math.max(0, (profile.Arc or 0) * 0.5)
    local angularPadding = math.asin(math.clamp(
        directionalPadding / math.max(distance, 0.001),
        0,
        0.98
    ))
    local allowedAngle = math.min(
        math.pi,
        halfArc + angularPadding + math.rad(8)
    )
    local facingAngle = math.acos(math.clamp(
        horizontalUnit(lookDirection):Dot(targetDirection),
        -1,
        1
    ))
    local travelHit = profile.TravelHitbox == true and dashAttack
        and (attackerAlignment or -1) >= DASH_CONFIRM_DOT
    if facingAngle > allowedAngle and not travelHit then
        return false, "not facing target"
    end
    return true, "directional"
end

local function rangedClearanceAt(
    threat,
    timeAhead,
    localPosition,
    attackerMotion,
    uncertainty
)
    local profile = threat.Profile
    local direction = unitOrFallback(
        threat.RangedDirection or threat.AimDirection,
        threat.LookDirection
    )
    local releaseIn = threat.RangedReleaseIn
    if releaseIn == nil then
        releaseIn = math.max(0, threat.EvaluationStart or 0)
    end
    local origin = threat.RangedOrigin or predictPosition(
        attackerMotion,
        releaseIn,
        true,
        threat.DashAttack
    )
    local targetStart = localPosition - Vector3.new(0, BODY_HALF_HEIGHT, 0)
    local targetEnd = localPosition + Vector3.new(0, BODY_HALF_HEIGHT, 0)
    local combinedRadius = BODY_RADIUS
        + (profile.ProjectileRadius or 0.35)
        + uncertainty

    if profile.ProjectileSpeed == math.huge then
        local shotEnd = origin
            + direction * (threat.RangedEffectiveRange or profile.Range)
        local clearance = math.sqrt(math.max(0, segmentDistanceSquared(
            origin,
            shotEnd,
            targetStart,
            targetEnd
        ))) - combinedRadius
        local temporalTolerance = math.max(
            0.025,
            2 * State.FrameMean + State.FrameDeviation
        )
        local relevant = math.abs(timeAhead - releaseIn) <= temporalTolerance
        return relevant and clearance <= 0, clearance
    end

    local flightAge
    if threat.RangedReleased then
        flightAge = (threat.RangedFlightAge or 0) + timeAhead
    else
        flightAge = timeAhead - releaseIn
    end
    local flightDuration = (threat.RangedEffectiveRange or profile.Range)
        / math.max(profile.ProjectileSpeed, 0.001)
    if flightAge < 0 or flightAge > flightDuration then
        return false, math.huge
    end
    local projectilePosition = origin
        + direction * profile.ProjectileSpeed * flightAge
    local clearance = math.sqrt(math.max(0, segmentDistanceSquared(
        projectilePosition,
        projectilePosition,
        targetStart,
        targetEnd
    ))) - combinedRadius
    return clearance <= 0, clearance
end

local function rangedProjectilePositionAt(threat, timeAhead)
    local profile = threat.Profile
    if profile.ProjectileSpeed == math.huge
        or profile.ProjectileSpeed <= 0
        or not threat.RangedOrigin then
        return nil
    end
    local flightAge
    if threat.RangedReleased then
        flightAge = (threat.RangedFlightAge or 0) + timeAhead
    else
        flightAge = timeAhead - (threat.RangedReleaseIn or 0)
    end
    local flightDuration = (threat.RangedEffectiveRange or profile.Range)
        / profile.ProjectileSpeed
    if flightAge < 0 or flightAge > flightDuration then
        return nil
    end
    return threat.RangedOrigin
        + unitOrFallback(threat.RangedDirection, threat.AimDirection)
            * profile.ProjectileSpeed * flightAge
end

local function finiteProjectileContact(
    threat,
    localMotion,
    releaseIn,
    maximumFlight,
    combinedRadius
)
    local intervalStart = releaseIn
    local intervalEnd = releaseIn + maximumFlight
    local firstProjectile = rangedProjectilePositionAt(threat, intervalStart)
    if not firstProjectile then
        return nil
    end
    local firstLocal = predictPosition(localMotion, intervalStart, true)
    local relativeSpeed = (
        (threat.RangedVelocity or ZERO)
            - predictVelocity(localMotion, intervalStart, true)
    ).Magnitude
    local steps = math.clamp(math.ceil(
        relativeSpeed * maximumFlight
            / math.max(2 * combinedRadius, 1)
    ), 6, 18)
    if maximumFlight <= 0.000001 then
        local entry = movingPointCapsuleEntry(
            firstProjectile - firstLocal,
            ZERO,
            BODY_HALF_HEIGHT,
            combinedRadius,
            0,
            0
        )
        return entry and intervalStart or nil
    end

    local previousTime = intervalStart
    local previousProjectile = firstProjectile
    local previousLocal = firstLocal
    for index = 1, steps do
        local sampleTime = intervalStart
            + maximumFlight * index / steps
        local projectile = rangedProjectilePositionAt(threat, sampleTime)
        if not projectile then
            break
        end
        local localPosition = predictPosition(localMotion, sampleTime, true)
        local duration = sampleTime - previousTime
        local relativeStart = previousProjectile - previousLocal
        local relativeVelocity = (
            projectile - previousProjectile - localPosition + previousLocal
        ) / duration
        local curvaturePadding = math.min(
            2,
            1200 * duration * duration / 8
        )
        local entry = movingPointCapsuleEntry(
            relativeStart,
            relativeVelocity,
            BODY_HALF_HEIGHT,
            combinedRadius + curvaturePadding,
            0,
            duration
        )
        if entry then
            return previousTime + entry
        end
        previousTime = sampleTime
        previousProjectile = projectile
        previousLocal = localPosition
    end
    return nil
end

local function forwardCapsuleHits(profile, attackerPosition, direction, localPosition, uncertainty)
    local attackCenter = attackerPosition + Vector3.new(0, 0.15, 0)
    local attackStart = attackCenter + direction * profile.NearReach
    local attackEnd = attackCenter + direction * profile.FarReach
    local targetStart = localPosition - Vector3.new(0, BODY_HALF_HEIGHT, 0)
    local targetEnd = localPosition + Vector3.new(0, BODY_HALF_HEIGHT, 0)
    local radius = profile.Radius + BODY_RADIUS + uncertainty
    return segmentDistanceSquared(
        attackStart,
        attackEnd,
        targetStart,
        targetEnd
    ) <= radius * radius
end

local function meleeArcDirection(profile, attackerPosition, look, localPosition)
    look = horizontalUnit(look)
    local toTarget = horizontalUnit(localPosition - attackerPosition, look)
    local signedAngle = math.atan2(
        look:Cross(toTarget).Y,
        math.clamp(look:Dot(toTarget), -1, 1)
    )
    local halfArc = math.max(0, (profile.Arc or 0) * 0.5)
    return rotateHorizontal(
        look,
        math.clamp(signedAngle, -halfArc, halfArc)
    )
end

local function attackHitsAt(
    threat,
    timeAhead,
    localMotion,
    attackerMotion,
    uncertainty,
    localPositionOverride,
    withAcceleration
)
    local profile = threat.Profile
    local localPosition = localPositionOverride
        or predictPosition(localMotion, timeAhead, withAcceleration)
    local attackerPosition = predictPosition(
        attackerMotion,
        timeAhead,
        withAcceleration,
        threat.DashAttack
    )

    if profile.Kind == "Area" then
        local separation = localPosition - attackerPosition
        separation = Vector3.new(separation.X, separation.Y * 0.55, separation.Z)
        local radius = profile.Radius + BODY_RADIUS + uncertainty
        return separation:Dot(separation) <= radius * radius
    end

    if profile.Kind == "Ranged" then
        local hit = rangedClearanceAt(
            threat,
            timeAhead,
            localPosition,
            attackerMotion,
            uncertainty
        )
        return hit
    end

    if profile.Kind ~= "Melee" then
        return false
    end

    if threat.WeaponSample then
        local weaponBase, weaponTip, weaponRadius = weaponSegmentAt(
            threat,
            timeAhead,
            attackerMotion
        )
        if weaponBase then
            return segmentCapsuleClearance(
                weaponBase,
                weaponTip,
                localPosition,
                BODY_RADIUS + weaponRadius + uncertainty
            ) <= 0
        end
    end

    local look = threat.LookDirection
    if forwardCapsuleHits(
        profile,
        attackerPosition,
        meleeArcDirection(
            profile,
            attackerPosition,
            look,
            localPosition
        ),
        localPosition,
        uncertainty
    ) then
        return true
    end

    if threat.DashAttack and profile.TravelHitbox == true then
        local travelDirection = horizontalUnit(attackerMotion.ShortVelocity, look)
        if forwardCapsuleHits(
            profile,
            attackerPosition,
            travelDirection,
            localPosition,
            uncertainty
        ) then
            return true
        end
    end
    return false
end

local evaluatePhysicalThreat

local function evaluateThreat(threat, now, localCharacter, localRoot, localMotion)
    if threat.PhysicalProjectile and evaluatePhysicalThreat then
        return evaluatePhysicalThreat(
            threat,
            now,
            localCharacter,
            localRoot,
            localMotion
        )
    end
    local attackerCharacter = threat.Character
    local watcher = attackerCharacter and State.Watchers[attackerCharacter]
    local attackerHumanoid = watcher and watcher.Humanoid
    local attackerRoot = watcher and watcher.Root
    local frozenFlight = threat.Profile.Kind == "Ranged"
        and threat.RangedReleased
        and threat.Profile.ProjectileSpeed ~= math.huge
        and threat.RangedState == "Flight"
    if not localCharacter or not localRoot or not localMotion then
        return false, "terminal"
    end
    if not frozenFlight and (
        not watcher or not attackerHumanoid or not attackerRoot
        or attackerHumanoid.Health <= 0
        or attackerCharacter.Parent ~= Live
    ) then
        return false, "terminal"
    end

    if watcher and attackerRoot
        and (not watcher.Motion
            or now - watcher.Motion.SampleAt > State.FrameMean * 1.5) then
        watcher.Motion = sampleMotion(watcher.Motion, attackerRoot, now)
    end
    local attackerMotion = watcher and watcher.Motion or threat.AttackerMotion
    if not attackerMotion then
        return false, "terminal"
    end
    local profile = threat.Profile
    if watcher and profile.Kind == "Melee" and profile.WeaponParts then
        local weaponSample = sampleWeaponSegment(watcher, profile, now)
        threat.WeaponSample = weaponSample
        if weaponSample and not threat.CountedLiveWeapon then
            threat.CountedLiveWeapon = true
            State.LiveWeaponThreats += 1
        end
    end
    local currentAim = attackerRoot and unitOrFallback(
        attackerRoot.CFrame.LookVector,
        threat.AimDirection or threat.LookDirection
    ) or unitOrFallback(threat.RangedDirection, threat.AimDirection)
    local currentLaunchOrigin = attackerMotion.Position
    if profile.Kind == "Ranged" and not threat.RangedReleased then
        currentLaunchOrigin, currentAim = readLaunchSource(
            threat.LaunchSource,
            threat.LaunchSourceUsesDirection,
            currentLaunchOrigin,
            currentAim
        )
    end
    threat.AttackerMotion = attackerMotion
    threat.AimDirection = currentAim
    threat.LookDirection = horizontalUnit(currentAim, threat.LookDirection)

    local previousRangedElapsed = threat.LastRangedElapsed
    local previousRangedAt = threat.LastRangedAt
    local previousRangedPosition = threat.LastRangedAttackerPosition
    local previousRangedAim = threat.LastRangedAimDirection
    local previousRangedLocalPosition = threat.LastRangedLocalPosition
    local activeStart, activeEnd, elapsed,
        effectiveStart, effectiveEnd, effectiveRelease = updateThreatClock(
            threat,
            now
        )
    local cancellationPhase = profile.Kind == "Ranged"
        and effectiveRelease or effectiveStart
    if threat.Track
        and not threat.Track.IsPlaying
        and elapsed < cancellationPhase - POST_ACTIVE_TOLERANCE
        and not threat.DashAttack then
        threat.StoppedBeforeActiveAt = threat.StoppedBeforeActiveAt or now
        if now - threat.StoppedBeforeActiveAt > 0.08 then
            return false, "finished"
        end
    else
        threat.StoppedBeforeActiveAt = nil
    end
    if profile.Kind ~= "Ranged"
        and elapsed > effectiveEnd + POST_ACTIVE_TOLERANCE then
        return false, "finished"
    end
    activeStart = math.clamp(activeStart, 0, MAX_PREDICTION_TIME)
    activeEnd = math.clamp(activeEnd, 0, MAX_PREDICTION_TIME)
    if activeEnd < activeStart then
        activeEnd = activeStart
    end
    if profile.Kind ~= "Ranged" then
        threat.ExpiresAt = math.max(
            threat.ExpiresAt,
            math.min(threat.CreatedAt + 4, now + activeEnd + 0.25)
        )
    end

    local relativePosition = localMotion.Position - attackerMotion.Position
    local currentDistance = relativePosition.Magnitude
    local targetDirection = horizontalUnit(relativePosition, threat.LookDirection)
    threat.TargetDirection = targetDirection
    threat.IntentModel = attackerMotion.Intent or "Continue"
    threat.IntentConfidence = attackerMotion.IntentConfidence or 0.35
    local attackerVelocity = predictionVelocity(attackerMotion, true)
    local attackerApproachSpeed = attackerVelocity:Dot(targetDirection)
    local attackerApproachAcceleration = attackerMotion.Acceleration:Dot(
        targetDirection
    )
    local attackerAlignment = attackerVelocity.Magnitude > 1
        and horizontalUnit(attackerVelocity, threat.LookDirection):Dot(
            targetDirection
        )
        or 0
    local recentDash = State.RecentEnemyDashes[attackerCharacter]
    local dashHint = recentDash and recentDash >= now
        or (threat.DashHintUntil or 0) >= now
    local baseReach = math.max(
        profile.Range or 0,
        profile.FarReach or 0,
        profile.Radius or 0
    ) + BODY_RADIUS
    local dashAligned = attackerApproachSpeed >= DASH_CONFIRM_MIN_SPEED
        and attackerAlignment >= DASH_CONFIRM_DOT
    local closeDash = currentDistance <= baseReach + 2
    if dashHint and (dashAligned or closeDash)
        or attackerApproachSpeed >= DASH_CLOSING_SPEED
            and attackerAlignment >= DASH_CONFIRM_DOT
        or attackerApproachAcceleration >= DASH_CLOSING_ACCELERATION
            and dashAligned then
        threat.DashConfirmedUntil = now + DASH_CONFIRM_HOLD
    end
    -- Dash animations are only hints.  A sideways/away dash must not remain
    -- latched as an incoming attack for the rest of the animation.
    threat.DashAttack = (threat.DashConfirmedUntil or 0) >= now

    local relativeVelocity = localMotion.Velocity
        - predictionVelocity(attackerMotion, threat.DashAttack)
    local relativeAcceleration = localMotion.Acceleration
        - attackerMotion.Acceleration
    local closingSpeed = currentDistance > 0.01
        and -relativePosition.Unit:Dot(relativeVelocity)
        or 0

    local lead = getPredictionLead(profile, threat.TimingKey)
    local uncertainty = uncertaintyFor(
        profile,
        localMotion,
        attackerMotion,
        activeEnd
    )
    local broadRadius = profile.Range + BODY_RADIUS + uncertainty
    local relevant, relevanceReason = analyticThreatRelevant(
        profile,
        currentDistance,
        targetDirection,
        threat.LookDirection,
        closingSpeed,
        attackerApproachSpeed,
        attackerApproachAcceleration,
        activeEnd + math.min(lead, 0.12),
        uncertainty,
        threat.DashAttack,
        attackerAlignment,
        threat.WeaponSample ~= nil
    )
    threat.FacingDot = threat.LookDirection:Dot(targetDirection)
    threat.RelevanceReason = relevanceReason
    if not relevant then
        if not threat.WasRelevanceGated
            or threat.LastGateReason ~= relevanceReason then
            State.ReachGateRejects += relevanceReason == "out of reach" and 1 or 0
            State.FacingGateRejects += relevanceReason == "not facing target" and 1 or 0
        end
        threat.WasRelevanceGated = true
        threat.LastGateReason = relevanceReason
        threat.CurrentDistance = currentDistance
        threat.ClosingSpeed = closingSpeed
        threat.AttackerApproachSpeed = attackerApproachSpeed
        threat.AttackerAlignment = attackerAlignment
        threat.EvaluationStart = activeStart
        threat.EvaluationEnd = activeEnd
        threat.Uncertainty = uncertainty
        threat.Emergency = false
        threat.ContactIn = nil
        threat.ImpactEarliest = nil
        threat.ImpactLatest = nil
        threat.CandidateImpactAt = nil
        threat.Deadline = math.huge
        threat.LastEvaluatedAt = now
        threat.PreviousRelative = relativePosition
        threat.PreviousRelativeAt = now
        if threat.LastConfirmedAt
            and now - threat.LastConfirmedAt > math.max(0.06, 2 * State.FrameMean) then
            threat.CountedPrediction = false
            threat.FirstConfirmedAt = nil
        end
        return true
    end
    threat.WasRelevanceGated = false
    threat.LastGateReason = nil
    local emergency = false
    local weaponSample = threat.WeaponSample
    if weaponSample and weaponSample.PreviousAt
        and weaponSample.At > weaponSample.PreviousAt then
        local sampleAge = weaponSample.At - weaponSample.PreviousAt
        local previousPhase = elapsed
            - sampleAge * math.max(threat.PlaybackSpeed, 0.05)
        local overlapsActive = previousPhase
                <= effectiveEnd + POST_ACTIVE_TOLERANCE
            and elapsed >= effectiveStart - POST_ACTIVE_TOLERANCE
        if sampleAge >= 0.002 and sampleAge <= WEAPON_SAMPLE_TTL
            and overlapsActive then
            local entry = sweptMovingSegmentCapsuleEntry(
                weaponSample.PreviousBase,
                weaponSample.PreviousTip,
                weaponSample.Base,
                weaponSample.Tip,
                localMotion.PreviousPosition or localMotion.Position,
                localMotion.Position,
                BODY_RADIUS + weaponSample.Radius + uncertainty,
                sampleAge
            )
            if entry then
                emergency = true
                local observedPhase = previousPhase
                    + entry / sampleAge * (elapsed - previousPhase)
                local calibration = calibrationFor(
                    profile,
                    threat.TimingKey
                )
                if observedPhase < profile.ActiveStart then
                    robustUpdate(
                        calibration.StartEarly,
                        profile.ActiveStart - observedPhase,
                        0,
                        0.12,
                        0.035
                    )
                elseif observedPhase > profile.ActiveEnd then
                    robustUpdate(
                        calibration.EndLate,
                        observedPhase - profile.ActiveEnd,
                        0,
                        0.12,
                        0.035
                    )
                end
                if not threat.CountedSweep then
                    threat.CountedSweep = true
                    State.SweptEmergencies += 1
                end
            end
        end
    end
    local previousRelative = threat.PreviousRelative
    local previousRelativeAt = threat.PreviousRelativeAt
    if not emergency and not weaponSample
        and previousRelative and previousRelativeAt then
        local sampleAge = now - previousRelativeAt
        local segment = relativePosition - previousRelative
        local denominator = segment:Dot(segment)
        local fraction = denominator > 0.000001
            and math.clamp(
                -previousRelative:Dot(segment) / denominator,
                0,
                1
            )
            or 0
        local sweptDistance = (previousRelative + segment * fraction).Magnitude
        local previousDistance = previousRelative.Magnitude
        local enteredOrApproaching = previousDistance > broadRadius
            or currentDistance < previousDistance - 0.05
        local timeAgo = (1 - fraction) * sampleAge
        local phaseAtClosest = elapsed
            - timeAgo * math.max(threat.PlaybackSpeed, 0.05)
        local facingAtClosest = profile.Kind == "Area"
            or threat.LookDirection:Dot(targetDirection)
                >= (profile.Facing or 0) - 0.2
            or threat.DashAttack and attackerAlignment > 0.25
        if profile.Kind ~= "Ranged"
            and sampleAge >= 0.002
            and sampleAge <= 0.12
            and denominator > 0.01
            and enteredOrApproaching
            and (threat.DashAttack and profile.TravelHitbox == true
                or attackerApproachSpeed >= DASH_CLOSING_SPEED)
            and phaseAtClosest >= effectiveStart - POST_ACTIVE_TOLERANCE
            and phaseAtClosest <= effectiveEnd + POST_ACTIVE_TOLERANCE
            and facingAtClosest
            and sweptDistance <= broadRadius then
            emergency = true
            if not threat.CountedSweep then
                threat.CountedSweep = true
                State.SweptEmergencies += 1
            end
        end
    end
    threat.PreviousRelative = relativePosition
    threat.PreviousRelativeAt = now

    local contactTime
    local absoluteImpactAt
    local evaluationStart = activeStart
    local evaluationEnd = activeEnd
    if emergency then
        contactTime = 0
    elseif profile.Kind == "Ranged" then
        if profile.ProjectileSpeed <= 0 then
            return false, "finished"
        end

        if not threat.RangedReleased and elapsed >= effectiveRelease then
            local launchAt
            local origin
            local direction
            local localAtLaunch
            if previousRangedElapsed
                and previousRangedAt
                and previousRangedPosition
                and previousRangedAim
                and previousRangedLocalPosition
                and previousRangedElapsed < effectiveRelease
                and elapsed > previousRangedElapsed then
                local fraction = math.clamp(
                    (effectiveRelease - previousRangedElapsed)
                        / (elapsed - previousRangedElapsed),
                    0,
                    1
                )
                launchAt = previousRangedAt
                    + (now - previousRangedAt) * fraction
                origin = previousRangedPosition:Lerp(
                    currentLaunchOrigin,
                    fraction
                )
                direction = unitOrFallback(
                    previousRangedAim:Lerp(currentAim, fraction),
                    currentAim
                )
                localAtLaunch = previousRangedLocalPosition:Lerp(
                    localMotion.Position,
                    fraction
                )
            else
                local backdate = math.clamp(
                    (elapsed - effectiveRelease)
                        / math.max(threat.PlaybackSpeed, 0.05),
                    0,
                    0.12
                )
                launchAt = now - backdate
                origin = currentLaunchOrigin
                    - predictionVelocity(attackerMotion, threat.DashAttack)
                        * backdate
                direction = currentAim
                localAtLaunch = localMotion.Position
                    - predictionVelocity(localMotion, false) * backdate
            end
            threat.RangedReleased = true
            threat.RangedState = "Flight"
            threat.RangedLaunchAt = launchAt
            threat.RangedOrigin = origin
            threat.RangedDirection = direction
            threat.RangedLocalAtLaunch = localAtLaunch
            threat.RangedEffectiveRange = effectiveShotRange(
                attackerCharacter,
                localCharacter,
                origin,
                direction,
                profile.Range
            )
            threat.RangedVelocity = profile.ProjectileSpeed == math.huge
                and ZERO
                or direction * profile.ProjectileSpeed
            if profile.ProjectileSpeed == math.huge then
                threat.RangedFlightEndAt = launchAt
            else
                threat.RangedFlightEndAt = launchAt
                    + threat.RangedEffectiveRange / profile.ProjectileSpeed
                threat.ExpiresAt = threat.RangedFlightEndAt
                    + math.max(State.FrameMean, 0.025)
            end
        elseif not threat.RangedReleased then
            threat.RangedState = "Windup"
            local releaseIn = math.max(
                0,
                (effectiveRelease - elapsed)
                    / math.max(threat.PlaybackSpeed, 0.05)
            )
            threat.RangedReleaseIn = releaseIn
            threat.RangedOrigin = predictPosition(
                attackerMotion,
                releaseIn,
                true,
                threat.DashAttack
            )
                + (currentLaunchOrigin - attackerMotion.Position)
            threat.RangedDirection = currentAim
            local lastTraceAim = threat.LastTrajectoryAim
            local lastTraceOrigin = threat.LastTrajectoryOrigin
            local aimChanged = not lastTraceAim
                or lastTraceAim:Dot(currentAim) < 0.995
            local originChanged = not lastTraceOrigin
                or (lastTraceOrigin - threat.RangedOrigin).Magnitude > 2
            local urgentTrace = activeStart <= lead + 0.12
            if urgentTrace or aimChanged or originChanged
                or now >= (threat.NextTrajectoryTraceAt or 0) then
                threat.RangedEffectiveRange = effectiveShotRange(
                    attackerCharacter,
                    localCharacter,
                    threat.RangedOrigin,
                    currentAim,
                    profile.Range
                )
                threat.NextTrajectoryTraceAt = now + 0.1
                threat.LastTrajectoryAim = currentAim
                threat.LastTrajectoryOrigin = threat.RangedOrigin
            end
            threat.RangedVelocity = profile.ProjectileSpeed == math.huge
                and ZERO
                or currentAim * profile.ProjectileSpeed
            local windupLifetime = activeStart + 0.25
            if profile.ProjectileSpeed ~= math.huge then
                windupLifetime += (threat.RangedEffectiveRange or profile.Range)
                    / profile.ProjectileSpeed
            end
            threat.ExpiresAt = math.max(
                threat.ExpiresAt,
                math.min(threat.CreatedAt + 5, now + windupLifetime)
            )
        end

        threat.LastRangedElapsed = elapsed
        threat.LastRangedAt = now
        threat.LastRangedAttackerPosition = currentLaunchOrigin
        threat.LastRangedAimDirection = currentAim
        threat.LastRangedLocalPosition = localMotion.Position

        local releaseIn
        local flightAge = 0
        if threat.RangedReleased then
            releaseIn = 0
            flightAge = math.max(0, now - threat.RangedLaunchAt)
        else
            releaseIn = math.max(
                0,
                (effectiveRelease - elapsed)
                    / math.max(threat.PlaybackSpeed, 0.05)
            )
        end
        threat.RangedReleaseIn = releaseIn
        threat.RangedFlightAge = flightAge

        local combinedRadius = BODY_RADIUS
            + (profile.ProjectileRadius or 0.35)
            + uncertainty
        if profile.ProjectileSpeed == math.huge then
            if threat.RangedResolved and now > threat.RangedResolvedAt then
                return false, "finished"
            end
            local localAtFire = threat.RangedReleased
                and threat.RangedLocalAtLaunch
                or predictPosition(localMotion, releaseIn, true)
            local targetStart = localAtFire
                - Vector3.new(0, BODY_HALF_HEIGHT, 0)
            local targetEnd = localAtFire
                + Vector3.new(0, BODY_HALF_HEIGHT, 0)
            local shotEnd = threat.RangedOrigin
                + threat.RangedDirection
                    * (threat.RangedEffectiveRange or profile.Range)
            if segmentDistanceSquared(
                threat.RangedOrigin,
                shotEnd,
                targetStart,
                targetEnd
            ) <= combinedRadius * combinedRadius then
                contactTime = releaseIn
                absoluteImpactAt = threat.RangedReleased
                    and threat.RangedLaunchAt
                    or now + releaseIn
            end
            if threat.RangedReleased then
                threat.RangedResolved = true
                threat.RangedResolvedAt = now
                threat.RangedState = "Spent"
            end
            evaluationStart = releaseIn
            evaluationEnd = releaseIn
        else
            local flightDuration = (threat.RangedEffectiveRange or profile.Range)
                / profile.ProjectileSpeed
            local maximumFlight
            if threat.RangedReleased then
                local remaining = threat.RangedFlightEndAt - now
                if remaining < 0 then
                    threat.RangedState = "Spent"
                    return false, "finished"
                end
                maximumFlight = math.max(
                    0,
                    math.min(remaining, MAX_PREDICTION_TIME)
                )
            else
                maximumFlight = math.min(
                    flightDuration,
                    math.max(0, MAX_PREDICTION_TIME - releaseIn)
                )
            end
            contactTime = finiteProjectileContact(
                threat,
                localMotion,
                releaseIn,
                maximumFlight,
                combinedRadius
            )
            evaluationStart = 0
            evaluationEnd = math.min(
                MAX_PREDICTION_TIME,
                releaseIn + maximumFlight
            )
        end

        if contactTime and contactTime <= lead + 0.12 then
            if now >= (threat.NextLineOfSightAt or 0) then
                local lineOrigin
                if threat.RangedReleased
                    and profile.ProjectileSpeed ~= math.huge then
                    lineOrigin = threat.RangedOrigin
                        + threat.RangedVelocity * flightAge
                else
                    lineOrigin = threat.RangedOrigin
                end
                local lineTarget = predictPosition(
                    localMotion,
                    contactTime,
                    true
                )
                threat.LineOfSight = hasLineOfSightBetween(
                    attackerCharacter,
                    localCharacter,
                    lineOrigin,
                    lineTarget
                )
                threat.NextLineOfSightAt = now + 0.05
            end
            if threat.LineOfSight == false then
                contactTime = nil
            end
        end
    else
        local timingUncertainty = math.min(
            0.08,
            State.FrameMean + 2 * State.FrameDeviation
        )
        local windowStart = math.max(0, activeStart - timingUncertainty)
        local windowEnd = math.min(
            MAX_PREDICTION_TIME,
            activeEnd + timingUncertainty
        )
        if threat.WeaponSample then
            contactTime = weaponContactTime(
                threat,
                localMotion,
                attackerMotion,
                windowStart,
                windowEnd,
                uncertainty
            )
        else
            local broadEntry = sphereEntry(
                relativePosition,
                relativeVelocity,
                broadRadius,
                windowStart,
                windowEnd
            )

            if not broadEntry
                and (threat.DashAttack or relativeAcceleration.Magnitude > 80) then
                for sampleIndex = 0, 5 do
                    local sampleTime = windowStart
                        + (windowEnd - windowStart) * sampleIndex / 5
                    local acceleratedRelative = predictPosition(
                        localMotion,
                        sampleTime,
                        true
                    ) - predictPosition(
                        attackerMotion,
                        sampleTime,
                        true,
                        threat.DashAttack
                    )
                    if acceleratedRelative.Magnitude <= broadRadius then
                        broadEntry = sampleTime
                        break
                    end
                end
            end

            if broadEntry then
                local relativeSpeed = relativeVelocity.Magnitude
                local sampleWidth = math.max(
                    2 * (profile.Radius or profile.Range)
                        + 2 * BODY_RADIUS + 2 * uncertainty,
                    1
                )
                local steps = math.clamp(math.ceil(
                    relativeSpeed * (windowEnd - windowStart) / sampleWidth
                ), 6, 12)
                local previousTime = windowStart
                for sampleIndex = 0, steps do
                    local sampleTime = windowStart
                        + (windowEnd - windowStart) * sampleIndex / steps
                    local hit = attackHitsAt(
                        threat,
                        sampleTime,
                        localMotion,
                        attackerMotion,
                        uncertainty,
                        nil,
                        false
                    ) or attackHitsAt(
                        threat,
                        sampleTime,
                        localMotion,
                        attackerMotion,
                        uncertainty,
                        nil,
                        true
                    )
                    if hit then
                        local low = previousTime
                        local high = sampleTime
                        for _ = 1, 4 do
                            local middle = (low + high) * 0.5
                            if attackHitsAt(
                                threat,
                                middle,
                                localMotion,
                                attackerMotion,
                                uncertainty,
                                nil,
                                true
                            ) then
                                high = middle
                            else
                                low = middle
                            end
                        end
                        contactTime = high
                        break
                    end
                    previousTime = sampleTime
                end

                local travelAlignment = horizontalUnit(
                    predictionVelocity(attackerMotion, true),
                    threat.LookDirection
                ):Dot(targetDirection)
                if not contactTime and threat.DashAttack
                    and profile.TravelHitbox == true
                    and attackerApproachSpeed > 3
                    and travelAlignment > 0.25 then
                    contactTime = broadEntry
                end
            end

            if not contactTime
                and currentDistance <= profile.Range + uncertainty
                and activeStart <= lead + State.FrameMean then
                local hitAtStart = attackHitsAt(
                    threat,
                    activeStart,
                    localMotion,
                    attackerMotion,
                    uncertainty,
                    nil,
                    true
                )
                local hitAtEnd = activeEnd > activeStart and attackHitsAt(
                    threat,
                    activeEnd,
                    localMotion,
                    attackerMotion,
                    uncertainty,
                    nil,
                    true
                )
                if hitAtStart or hitAtEnd then
                    contactTime = activeStart
                end
            end
        end
    end

    threat.CurrentDistance = currentDistance
    threat.ClosingSpeed = closingSpeed
    threat.AttackerApproachSpeed = attackerApproachSpeed
    threat.AttackerAlignment = attackerAlignment
    threat.EvaluationStart = evaluationStart
    threat.EvaluationEnd = evaluationEnd
    threat.Uncertainty = uncertainty
    threat.Emergency = emergency
    threat.ContactIn = contactTime
    threat.ImpactEarliest, threat.ImpactLatest = State:ContactIntervalFor(
        threat,
        contactTime
    )
    local intervalAdvance = contactTime and threat.ImpactEarliest
        and contactTime - threat.ImpactEarliest or 0
    threat.CandidateImpactAt = contactTime
        and (absoluteImpactAt and absoluteImpactAt - intervalAdvance
            or now + threat.ImpactEarliest)
        or nil
    threat.Deadline = threat.CandidateImpactAt
        and threat.CandidateImpactAt - lead
        or math.huge
    threat.LastEvaluatedAt = now
    if contactTime then
        threat.LastConfirmedAt = now
    elseif threat.LastConfirmedAt
        and now - threat.LastConfirmedAt > math.max(0.06, 2 * State.FrameMean) then
        threat.CountedPrediction = false
        threat.FirstConfirmedAt = nil
    end
    if contactTime and not threat.CountedPrediction then
        threat.CountedPrediction = true
        threat.FirstConfirmedAt = os.clock()
        State.PredictedThreats += 1
        pushReplay("contact_predicted", now, {
            Threat = threat.Profile.Name,
            Contact = contactTime,
            Confidence = threat.Confidence or 0.75,
        })
    end
    return true
end

local function removeThreatAt(index)
    local pending = State.Pending
    local threat = pending[index]
    if not threat then
        return
    end
    local physical = threat.PhysicalProjectile
    if physical and physical.Threat == threat then
        physical.Threat = nil
    end
    if State.DodgePlan and State.DodgePlan.Threat == threat then
        State.DodgePlan = nil
    end
    State.PendingIndex[threat.Key] = nil
    local lastIndex = #pending
    local lastThreat = pending[lastIndex]
    pending[lastIndex] = nil
    if index < lastIndex then
        pending[index] = lastThreat
        State.PendingIndex[lastThreat.Key] = index
    end
    State.PendingCount = #pending
end

local function addThreat(threat)
    local existingIndex = State.PendingIndex[threat.Key]
    if existingIndex then
        State.Pending[existingIndex] = threat
        return true
    end

    if #State.Pending >= MAX_PENDING then
        local worstIndex = 1
        local worstUrgency = -math.huge
        for index, existing in ipairs(State.Pending) do
            local urgency = existing.Deadline or existing.PreliminaryDeadline
            if urgency > worstUrgency then
                worstUrgency = urgency
                worstIndex = index
            end
        end
        if threat.PreliminaryDeadline >= worstUrgency
            and threat.InitialDistance > threat.Profile.Range * 2 then
            return false
        end
        removeThreatAt(worstIndex)
    end

    local index = #State.Pending + 1
    State.Pending[index] = threat
    State.PendingIndex[threat.Key] = index
    State.PendingCount = index
    return true
end

local function normalizedObjectName(value)
    return string.lower(tostring(value or "")):gsub("[^%w]", "")
end

local function projectileSignatureFor(object)
    if not object or hasGunToken(object.Name) then
        return nil
    end
    local normalized = normalizedObjectName(object.Name)
    for key, specification in pairs(PROJECTILE_SIGNATURES) do
        if normalized == key
            or normalized == key .. "projectile"
            or normalized == "thrown" .. key
            or normalized:match("^" .. key .. "%d+$") then
            return key, specification
        end
    end
    for _, attributeName in ipairs({
        "ProjectileType", "WeaponType", "Weapon", "ItemType",
    }) do
        local value = object:GetAttribute(attributeName)
        local key = normalizedObjectName(value)
        if PROJECTILE_SIGNATURES[key] and not hasGunToken(value) then
            return key, PROJECTILE_SIGNATURES[key]
        end
    end
    return nil
end

local function largestPartIn(object)
    if object:IsA("BasePart") then
        return object
    end
    if object:IsA("Model") and object.PrimaryPart then
        return object.PrimaryPart
    end
    local best
    local bestVolume = -1
    local scanned = 0
    for _, descendant in ipairs(object:GetDescendants()) do
        scanned += 1
        if scanned > 96 then
            break
        end
        if descendant:IsA("BasePart") and not hasGunToken(descendant.Name) then
            local size = descendant.Size
            local volume = size.X * size.Y * size.Z
            if volume > bestVolume then
                best = descendant
                bestVolume = volume
            end
        end
    end
    return best
end

local function projectileBox(record)
    local part = record.Part
    if not part or not part.Parent then
        return nil
    end
    local boxCFrame = part.CFrame * record.BoxOffset
    local size = record.BoxSize
    local direction
    local length
    local minorFirst
    local minorSecond
    if size.X >= size.Y and size.X >= size.Z then
        direction = boxCFrame.RightVector
        length = size.X
        minorFirst, minorSecond = size.Y, size.Z
    elseif size.Y >= size.Z then
        direction = boxCFrame.UpVector
        length = size.Y
        minorFirst, minorSecond = size.X, size.Z
    else
        direction = boxCFrame.LookVector
        length = size.Z
        minorFirst, minorSecond = size.X, size.Y
    end
    local half = direction * length * 0.5
    local geometryRadius = 0.5 * math.sqrt(
        minorFirst * minorFirst + minorSecond * minorSecond
    )
    return boxCFrame.Position - half,
        boxCFrame.Position + half,
        math.clamp(
            math.max(record.Specification.Radius, geometryRadius),
            0.12,
            2.75
        )
end

local function registerProjectile(object, generation)
    if not State.Enabled or generation ~= State.Generation
        or not Effects or not object or object.Parent ~= Effects
        or State.Projectiles[object]
        or State.ProjectileCount >= MAX_PROJECTILES then
        return nil
    end
    local signature, specification = projectileSignatureFor(object)
    if not signature then
        return nil
    end
    local part = largestPartIn(object)
    if not part or hasGunToken(part.Name) then
        return nil
    end
    local boxCFrame = part.CFrame
    local boxSize = part.Size
    if object:IsA("Model") then
        local ok, modelCFrame, modelSize = pcall(object.GetBoundingBox, object)
        if ok and finiteVector(modelCFrame.Position) then
            boxCFrame = modelCFrame
            boxSize = modelSize
        end
    end
    local record = {
        Object = object,
        -- Keep the actual geometry part. AssemblyRootPart can be the thrower's
        -- root while a weapon is welded and can change after release.
        Part = part,
        Signature = signature,
        Specification = specification,
        CreatedAt = os.clock(),
        ExpiresAt = os.clock() + math.min(
            PROJECTILE_HARD_TTL,
            specification.TTL or PROJECTILE_HARD_TTL
        ),
        BoxOffset = part.CFrame:ToObjectSpace(boxCFrame),
        BoxSize = boxSize,
        StableSamples = 0,
        Velocity = ZERO,
        Acceleration = ZERO,
        TangentialAcceleration = 0,
        TurnAxis = Vector3.new(0, 1, 0),
        TurnRate = 0,
        HomingStrength = 0,
        Model = "Linear",
        ModelConfidence = 0.35,
        BounceCount = 0,
        LastBounceAt = -math.huge,
        History = table.create(PROJECTILE_HISTORY_LIMIT),
        HistoryHead = 0,
        HistoryCount = 0,
        ClearFrames = 0,
        PositionJitter = 0.1,
        LocalOwned = false,
    }
    local localCharacter, _, localRoot = getLocalCharacter()
    if localRoot then
        local localDistance = (boxCFrame.Position - localRoot.Position).Magnitude
        local nearestEnemy = math.huge
        for character, watcher in pairs(State.Watchers) do
            if character ~= localCharacter and watcher.Root then
                nearestEnemy = math.min(
                    nearestEnemy,
                    (boxCFrame.Position - watcher.Root.Position).Magnitude
                )
            end
        end
        record.LocalOwned = localDistance < 11
            and localDistance + 2 < nearestEnemy
    end
    local ownerUserId = object:GetAttribute("OwnerUserId")
        or object:GetAttribute("UserId")
    if ownerUserId == LocalPlayer.UserId then
        record.LocalOwned = true
    end
    State.Projectiles[object] = record
    State.ProjectileList[#State.ProjectileList + 1] = record
    State.ProjectileCount += 1
    State.ProjectileCandidatesSeen += 1
    return record
end

local function removeProjectileAt(index, now)
    local record = State.ProjectileList[index]
    if not record then
        return
    end
    State.Projectiles[record.Object] = nil
    if record.Threat then
        record.Threat.ExpiresAt = math.min(
            record.Threat.ExpiresAt or now,
            now
        )
        record.Threat.PhysicalProjectile = nil
        record.Threat = nil
    end
    local lastIndex = #State.ProjectileList
    State.ProjectileList[index] = State.ProjectileList[lastIndex]
    State.ProjectileList[lastIndex] = nil
    State.ProjectileCount = #State.ProjectileList
end

local function pushProjectileHistory(record, now, center, velocity)
    local head = record.HistoryHead % PROJECTILE_HISTORY_LIMIT + 1
    local entry = record.History[head]
    if not entry then
        entry = {}
        record.History[head] = entry
    end
    entry.At = now
    entry.Position = center
    entry.Velocity = velocity
    record.HistoryHead = head
    record.HistoryCount = math.min(
        record.HistoryCount + 1,
        PROJECTILE_HISTORY_LIMIT
    )
end

local function projectileStaticParameters(record)
    local filter = { record.Object, Live }
    if Effects then
        filter[#filter + 1] = Effects
    end
    local camera = workspace.CurrentCamera
    if camera then
        filter[#filter + 1] = camera
    end
    local parameters = RaycastParams.new()
    parameters.FilterType = Enum.RaycastFilterType.Exclude
    parameters.FilterDescendantsInstances = filter
    parameters.IgnoreWater = true
    parameters.RespectCanCollide = true
    return parameters
end

local function confirmObservedBounce(
    record,
    previousCenter,
    previousVelocity,
    velocity,
    deltaTime,
    now
)
    local oldSpeed = previousVelocity.Magnitude
    local newSpeed = velocity.Magnitude
    if oldSpeed < 18 or newSpeed < 12 or deltaTime > 0.12
        or now - record.LastBounceAt < 0.08
        or record.BounceCount >= MAX_PREDICTED_BOUNCES then
        return false
    end
    local directionDot = previousVelocity.Unit:Dot(velocity.Unit)
    if directionDot > 0.35 then
        return false
    end
    local castDistance = math.clamp(oldSpeed * deltaTime * 1.75, 2, 18)
    local ok, result = pcall(
        workspace.Raycast,
        workspace,
        previousCenter,
        previousVelocity.Unit * castDistance,
        projectileStaticParameters(record)
    )
    if not ok or not result then
        return false
    end
    local reflected = previousVelocity
        - 2 * previousVelocity:Dot(result.Normal) * result.Normal
    if reflected.Magnitude < 0.001
        or reflected.Unit:Dot(velocity.Unit) < 0.55 then
        return false
    end
    record.BounceCount += 1
    record.LastBounceAt = now
    record.Model = "Bouncing"
    record.ModelConfidence = math.max(record.ModelConfidence, 0.82)
    pushReplay("projectile_bounce", now, {
        Signature = record.Signature,
        Speed = newSpeed,
        Count = record.BounceCount,
    })
    return true
end

local function sampleProjectileRecord(record, now)
    local base, tip, radius = projectileBox(record)
    if not base or not finiteVector(base) or not finiteVector(tip) then
        return false
    end
    local center = (base + tip) * 0.5
    local previousAt = record.SampleAt
    local previousCenter = record.Center
    local previousVelocity = record.Velocity
    record.PreviousBase = record.Base or base
    record.PreviousTip = record.Tip or tip
    record.PreviousCenter = record.Center or center
    record.PreviousAt = previousAt or now
    record.Base = base
    record.Tip = tip
    record.Center = center
    record.Radius = radius
    record.AngularVelocity = clampMagnitude(
        record.Part.AssemblyAngularVelocity,
        80
    )
    record.SampleAt = now
    if not previousAt then
        record.Velocity = clampMagnitude(
            record.Part.AssemblyLinearVelocity,
            1800
        )
        record.BaseVelocity = record.Velocity
        record.TipVelocity = record.Velocity
        pushProjectileHistory(record, now, center, record.Velocity)
        return true
    end
    local deltaTime = now - previousAt
    if deltaTime < 0.002 then
        return true
    end
    if deltaTime > 0.3 or (center - previousCenter).Magnitude > 500 then
        record.Velocity = clampMagnitude(record.Part.AssemblyLinearVelocity, 1800)
        record.BaseVelocity = record.Velocity
        record.TipVelocity = record.Velocity
        record.Acceleration = ZERO
        record.TangentialAcceleration = 0
        record.TurnRate = 0
        record.HomingStrength = 0
        record.Model = "Linear"
        record.ModelConfidence = 0.25
        record.StableSamples = 0
        table.clear(record.History)
        record.HistoryHead = 0
        record.HistoryCount = 0
        pushProjectileHistory(record, now, center, record.Velocity)
        return true
    end
    local measuredVelocity = clampMagnitude(
        (center - previousCenter) / deltaTime,
        1800
    )
    local assemblyVelocity = clampMagnitude(
        record.Part.AssemblyLinearVelocity,
        1800
    )
    local blend = record.Part.Anchored and 0 or 0.15
    local velocity = measuredVelocity:Lerp(assemblyVelocity, blend)
    record.BaseVelocity = clampMagnitude(
        (base - record.PreviousBase) / deltaTime,
        1800
    )
    record.TipVelocity = clampMagnitude(
        (tip - record.PreviousTip) / deltaTime,
        1800
    )
    local rawAcceleration = clampMagnitude(
        (velocity - previousVelocity) / deltaTime,
        2400
    )
    record.Acceleration = record.Acceleration:Lerp(
        rawAcceleration,
        1 - math.exp(-deltaTime / 0.055)
    )
    local previousSpeed = previousVelocity.Magnitude
    local speed = velocity.Magnitude
    local turnRate = 0
    local turnAxis = record.TurnAxis
    if previousSpeed > 4 and speed > 4 then
        local previousDirection = previousVelocity.Unit
        local direction = velocity.Unit
        local cross = previousDirection:Cross(direction)
        local sine = math.clamp(cross.Magnitude, 0, 1)
        local cosine = math.clamp(previousDirection:Dot(direction), -1, 1)
        turnRate = math.atan2(sine, cosine) / deltaTime
        if cross.Magnitude > 0.001 then
            turnAxis = cross.Unit
        end
        record.TangentialAcceleration += (
            (speed - previousSpeed) / deltaTime
                - record.TangentialAcceleration
        ) * 0.28
    end
    record.TurnRate += (math.clamp(turnRate, 0, 18) - record.TurnRate) * 0.3
    record.TurnAxis = turnAxis

    local localCharacter, _, localRoot = getLocalCharacter()
    if localRoot and speed > 4 then
        local targetDirection = unitOrFallback(localRoot.Position - center)
        local forward = velocity.Unit
        local targetLateral = targetDirection - forward * targetDirection:Dot(forward)
        local accelerationLateral = record.Acceleration
            - forward * record.Acceleration:Dot(forward)
        local homingEvidence = targetLateral.Magnitude > 0.05
            and accelerationLateral.Magnitude > 6
            and math.max(0, targetLateral.Unit:Dot(accelerationLateral.Unit))
            or 0
        record.HomingStrength += (
            homingEvidence - record.HomingStrength
        ) * 0.24
    else
        record.HomingStrength *= 0.9
    end
    local bounced = confirmObservedBounce(
        record,
        previousCenter,
        previousVelocity,
        velocity,
        deltaTime,
        now
    )
    if not bounced and now - record.LastBounceAt > 0.18 then
        local accelerationMagnitude = record.Acceleration.Magnitude
        if record.TurnRate > 0.3 and record.HomingStrength > 0.58
            and record.StableSamples >= 3 then
            record.Model = "Homing"
            record.ModelConfidence = math.clamp(
                0.45 + 0.45 * record.HomingStrength,
                0.45,
                0.95
            )
        elseif record.TurnRate > 0.35 and record.StableSamples >= 2 then
            record.Model = "Curved"
            record.ModelConfidence = math.clamp(
                0.45 + record.TurnRate / 20,
                0.45,
                0.88
            )
        elseif accelerationMagnitude > 35 and record.StableSamples >= 2 then
            record.Model = "Accelerating"
            record.ModelConfidence = math.clamp(
                0.45 + accelerationMagnitude / 2000,
                0.45,
                0.86
            )
        else
            record.Model = "Linear"
            record.ModelConfidence += (0.8 - record.ModelConfidence) * 0.12
        end
    end
    local residual = (center - previousCenter - previousVelocity * deltaTime).Magnitude
    record.PositionJitter += (
        residual - record.PositionJitter
    ) * (1 - math.exp(-8 * deltaTime))
    record.Velocity = velocity
    record.StableSamples = math.min(record.StableSamples + 1, 12)
    pushProjectileHistory(record, now, center, velocity)
    State.LastProjectileModel = record.Model
    return true
end

local function physicalProfileFor(record)
    local specification = record.Specification
    if not specification.Profile then
        specification.Profile = makeExactProfile(PROFILE_THROW, {
            Name = specification.Name .. " (physical)",
            Weapon = specification.Name,
            Kind = "Physical",
            ActiveStart = 0,
            ActiveEnd = specification.TTL or PROJECTILE_HARD_TTL,
            ReleaseAt = 0,
            Range = PROJECTILE_ACQUISITION_RANGE,
            ProjectileRadius = specification.Radius,
            ProjectileSignature = record.Signature,
            CalibrationKey = "Physical:" .. record.Signature,
        })
    end
    return specification.Profile
end

local function associateProjectile(record, now)
    local previousThreat = record.Threat
    if previousThreat and not previousThreat.PhysicalOnly then
        return record.Threat
    end
    local best
    local bestScore = math.huge
    for _, threat in ipairs(State.Pending) do
        local profile = threat.Profile
        if profile and profile.Kind == "Ranged"
            and not threat.PhysicalProjectile
            and not hasGunToken(profile.Name)
            and (not profile.ProjectileSignature
                or profile.ProjectileSignature == record.Signature) then
            local origin = threat.RangedOrigin
                or threat.LastRangedAttackerPosition
                or threat.AttackerMotion and threat.AttackerMotion.Position
            if origin then
                local distance = (record.Center - origin).Magnitude
                local phase = threat.Track and threat.Track.TimePosition
                    or threat.LogicalElapsed or 0
                local phaseError = phase - (profile.ReleaseAt or profile.ActiveStart)
                local score = distance + math.abs(phaseError) * 18
                if distance <= 24 and math.abs(phaseError) <= 0.65
                    and score < bestScore then
                    best = threat
                    bestScore = score
                end
            end
        end
    end
    if best then
        if previousThreat and previousThreat ~= best then
            local previousIndex = State.PendingIndex[previousThreat.Key]
            if previousIndex then
                removeThreatAt(previousIndex)
            else
                previousThreat.PhysicalProjectile = nil
                record.Threat = nil
            end
            State.ThreatFusions += 1
            pushReplay("threat_fused", now, {
                Signature = record.Signature,
                Threat = best.Profile.Name,
            })
        end
        record.Threat = best
        record.AttackerCharacter = best.Character
        record.LocalOwned = false
        best.PhysicalProjectile = record
        best.ExpiresAt = math.min(record.ExpiresAt, best.CreatedAt + 6)
        local phase = best.Track and best.Track.TimePosition
            or best.LogicalElapsed or 0
        local nominalRelease = best.Profile.ReleaseAt
            or best.Profile.ActiveStart
        -- First replication is an upper bound on release. Only evidence that
        -- the object existed early is allowed to advance the defensive time.
        if phase < nominalRelease then
            robustUpdate(
                calibrationFor(
                    best.Profile,
                    best.TimingKey
                ).ReleaseEarly,
                nominalRelease - phase,
                0,
                0.12,
                0.035
            )
        end
        State.PhysicalProjectilesTracked += 1
    end
    return best
end

local function projectileUncertaintyAt(record, timeAhead)
    local observationAge = math.max(0, os.clock() - (record.SampleAt or os.clock()))
    local modelPenalty = (1 - (record.ModelConfidence or 0.3)) * 2.2
    local turnPenalty = math.min(2.5, (record.TurnRate or 0) * timeAhead * 0.22)
    local accelerationPenalty = math.min(
        2.5,
        (record.Acceleration and record.Acceleration.Magnitude or 0)
            * timeAhead * timeAhead / 500
    )
    return math.clamp(
        0.25 + 1.6 * (record.PositionJitter or 0.1)
            + observationAge * math.min(30, record.Velocity.Magnitude * 0.08)
            + modelPenalty + turnPenalty + accelerationPenalty,
        0.25,
        7
    )
end

local function integrateProjectileStep(record, center, velocity, step, target)
    local model = record.Model
    if model == "Homing" and (
        (record.StableSamples or 0) < 4
        or (record.ModelConfidence or 0) < 0.72
        or (record.HomingStrength or 0) < 0.62
    ) then
        model = (record.TurnRate or 0) > 0.35 and "Curved" or "Linear"
    elseif model == "Curved" and (
        (record.StableSamples or 0) < 3
        or (record.ModelConfidence or 0) < 0.58
    ) then
        model = "Linear"
    end
    local speed = velocity.Magnitude
    if speed > 0.001 and (model == "Curved" or model == "Homing") then
        local direction = velocity.Unit
        if model == "Homing" and target then
            local desired = unitOrFallback(target - center, direction)
            local angle = math.acos(math.clamp(direction:Dot(desired), -1, 1))
            if angle > 0.0001 then
                local alpha = math.min(
                    1,
                    math.max(record.TurnRate, 0.35) * step / angle
                )
                direction = unitOrFallback(direction:Lerp(desired, alpha), direction)
            end
        else
            direction = unitOrFallback(rotateAroundAxis(
                direction,
                record.TurnAxis,
                math.min(record.TurnRate, 18) * step
            ), direction)
        end
        velocity = direction * speed
    end
    local acceleration = clampMagnitude(record.Acceleration, 1800)
    if model == "Linear" then
        acceleration *= 0.15
    elseif model == "Curved" or model == "Homing" then
        local forward = unitOrFallback(velocity)
        acceleration = forward * math.clamp(
            record.TangentialAcceleration or acceleration:Dot(forward),
            -1200,
            1200
        )
    end
    local displacement = velocity * step + acceleration * (0.5 * step * step)
    return center + displacement, velocity + acceleration * step, displacement
end

local function physicalSegmentAt(record, timeAhead, targetPosition)
    if not record.Base or not record.Tip then
        return nil
    end
    local time = math.clamp(timeAhead, 0, MAX_PREDICTION_TIME)
    local center = record.Center
    local velocity = record.Velocity
    local steps = math.clamp(math.ceil(time / 0.045), 1, MAX_SWEEP_STEPS)
    local step = steps > 0 and time / steps or 0
    for _ = 1, steps do
        center, velocity = integrateProjectileStep(
            record,
            center,
            velocity,
            step,
            targetPosition
        )
    end
    local half = (record.Tip - record.Base) * 0.5
    local angularVelocity = record.AngularVelocity or ZERO
    if angularVelocity.Magnitude > 0.001 then
        half = rotateAroundAxis(
            half,
            angularVelocity.Unit,
            math.min(angularVelocity.Magnitude, 80) * time
        )
    end
    return center - half, center + half, record.Radius
end

local function buildPhysicalTrajectory(record, localMotion, horizon, bodyPositionAt)
    local trajectory = record.Trajectory or table.create(MAX_SWEEP_STEPS + 1)
    record.Trajectory = trajectory
    local previousCount = record.TrajectoryCount or #trajectory
    local function writeSample(index, time, base, tip, uncertainty)
        local sample = trajectory[index]
        if not sample then
            sample = {}
            trajectory[index] = sample
        end
        sample.Time = time
        sample.Base = base
        sample.Tip = tip
        sample.Uncertainty = uncertainty
    end
    local relativeSpeed = (record.Velocity - localMotion.Velocity).Magnitude
    local stepTime = math.clamp(
        0.65 * (BODY_RADIUS + record.Radius)
            / math.max(relativeSpeed, 1),
        1 / 180,
        1 / 24
    )
    local steps = math.clamp(
        math.ceil(horizon / stepTime),
        4,
        MAX_SWEEP_STEPS
    )
    if horizon <= 0.000001 then
        steps = 1
    end
    local center = record.Center
    local velocity = record.Velocity
    local half = (record.Tip - record.Base) * 0.5
    writeSample(
        1,
        0,
        center - half,
        center + half,
        projectileUncertaintyAt(record, 0)
    )
    local bounceBudget = (record.BounceCount > 0
        or record.Model == "Bouncing"
        or record.Signature == "boomerang")
        and MAX_PREDICTED_BOUNCES or 0
    local parameters = bounceBudget > 0 and projectileStaticParameters(record)
        or nil
    local angularVelocity = record.AngularVelocity or ZERO
    local step = horizon / steps
    for index = 1, steps do
        local sampleTime = step * index
        local target = bodyPositionAt and bodyPositionAt(sampleTime)
            or predictPosition(localMotion, sampleTime, true)
        local nextCenter, nextVelocity, displacement = integrateProjectileStep(
            record,
            center,
            velocity,
            step,
            target
        )
        if bounceBudget > 0 and displacement.Magnitude > 0.05 then
            local ok, hit = pcall(
                workspace.Spherecast,
                workspace,
                center,
                math.max(record.Radius, 0.12),
                displacement,
                parameters
            )
            if ok and hit then
                nextCenter = hit.Position + hit.Normal * (record.Radius + 0.03)
                nextVelocity = nextVelocity
                    - 2 * nextVelocity:Dot(hit.Normal) * hit.Normal
                nextVelocity *= record.Signature == "boomerang" and 0.9 or 0.72
                bounceBudget -= 1
            end
        end
        if angularVelocity.Magnitude > 0.001 then
            half = rotateAroundAxis(
                half,
                angularVelocity.Unit,
                math.min(angularVelocity.Magnitude, 80) * step
            )
        end
        center = nextCenter
        velocity = nextVelocity
        writeSample(
            index + 1,
            sampleTime,
            center - half,
            center + half,
            projectileUncertaintyAt(record, sampleTime)
        )
    end
    local count = steps + 1
    for index = previousCount, count + 1, -1 do
        trajectory[index] = nil
    end
    record.TrajectoryCount = count
    return trajectory
end

local function physicalBroadPhaseMayHit(record, localMotion, horizon, uncertainty)
    local relative = record.Center - localMotion.Position
    local relativeVelocity = record.Velocity - localMotion.Velocity
    local speedSquared = relativeVelocity:Dot(relativeVelocity)
    local closestTime = speedSquared > 0.000001 and math.clamp(
        -relative:Dot(relativeVelocity) / speedSquared,
        0,
        horizon
    ) or 0
    local miss = (relative + relativeVelocity * closestTime).Magnitude
    local reliableHoming = record.Model == "Homing"
        and (record.StableSamples or 0) >= 4
        and (record.ModelConfidence or 0) >= 0.72
        and (record.HomingStrength or 0) >= 0.62
    local reliableCurve = record.Model == "Curved"
        and (record.StableSamples or 0) >= 3
        and (record.ModelConfidence or 0) >= 0.58
    local bouncing = record.Model == "Bouncing"
        or record.BounceCount > 0
        or record.Signature == "boomerang"
    if bouncing then
        return true
    end
    local maneuverPadding = 0
    if reliableHoming or reliableCurve then
        maneuverPadding = math.min(
            record.Velocity.Magnitude * horizon,
            0.5 * (
                record.Velocity.Magnitude * math.min(record.TurnRate or 0, 18)
                + math.min(record.Acceleration.Magnitude, 1800)
            ) * horizon * horizon
        )
    elseif record.Model == "Accelerating"
        and (record.ModelConfidence or 0) >= 0.58 then
        maneuverPadding = 0.5
            * math.min(record.Acceleration.Magnitude, 600)
            * horizon * horizon
    end
    local combined = BODY_RADIUS + record.Radius + uncertainty
        + maneuverPadding + 0.75
    return miss <= combined
end

local function physicalContactTime(record, localMotion, horizon, uncertainty, bodyPositionAt)
    local trajectory = buildPhysicalTrajectory(
        record,
        localMotion,
        horizon,
        bodyPositionAt
    )
    local previous = trajectory[1]
    local previousBody = bodyPositionAt and bodyPositionAt(0)
        or predictPosition(localMotion, 0, true)
    for index = 2, #trajectory do
        local sample = trajectory[index]
        local body = bodyPositionAt and bodyPositionAt(sample.Time)
            or predictPosition(localMotion, sample.Time, true)
        local duration = sample.Time - previous.Time
        local firstDirection = unitOrFallback(previous.Tip - previous.Base)
        local secondDirection = unitOrFallback(
            sample.Tip - sample.Base,
            firstDirection
        )
        local cosine = math.clamp(firstDirection:Dot(secondDirection), -1, 1)
        local rotationalPadding = math.max(
            (previous.Tip - previous.Base).Magnitude,
            (sample.Tip - sample.Base).Magnitude
        ) * (1 - math.sqrt(math.max(0, (1 + cosine) * 0.5)))
        local modelUncertainty = math.max(
            previous.Uncertainty,
            sample.Uncertainty
        )
        local combinedUncertainty = math.sqrt(
            uncertainty * uncertainty
                + modelUncertainty * modelUncertainty
        )
        local entry = sweptMovingSegmentCapsuleEntry(
            previous.Base,
            previous.Tip,
            sample.Base,
            sample.Tip,
            previousBody,
            body,
            BODY_RADIUS + record.Radius + combinedUncertainty
                + rotationalPadding,
            duration
        )
        if entry then
            return previous.Time + entry
        end
        previous = sample
        previousBody = body
    end
    return nil
end

evaluatePhysicalThreat = function(
    threat,
    now,
    localCharacter,
    localRoot,
    localMotion
)
    local record = threat.PhysicalProjectile
    if not record or not record.Object or not record.Object.Parent
        or not record.Part or not record.Part.Parent
        or now > record.ExpiresAt then
        return false, "finished"
    end
    if not localCharacter or not localRoot or not localMotion
        or not record.Center or record.StableSamples < 1 then
        return true
    end
    local relative = record.Center - localMotion.Position
    local distance = relative.Magnitude
    local relativeVelocity = record.Velocity - localMotion.Velocity
    local closing = distance > 0.01
        and -relative.Unit:Dot(relativeVelocity) or 0
    local horizon = math.min(
        MAX_PREDICTION_TIME,
        math.max(0, record.ExpiresAt - now)
    )
    local uncertainty = math.clamp(
        0.35 + 1.25 * (localMotion.PositionJitter or 0.1)
            + relativeVelocity.Magnitude
                * (State.FrameMean + 2 * State.FrameDeviation) * 0.2,
        0.35,
        3.5
    )
    local emergency = false
    if record.PreviousAt and record.SampleAt > record.PreviousAt
        and record.SampleAt - record.PreviousAt <= 0.12 then
        local entry = sweptMovingSegmentCapsuleEntry(
            record.PreviousBase,
            record.PreviousTip,
            record.Base,
            record.Tip,
            localMotion.PreviousPosition or localMotion.Position,
            localMotion.Position,
            BODY_RADIUS + record.Radius + uncertainty,
            record.SampleAt - record.PreviousAt
        )
        emergency = entry ~= nil
    end
    local broadPhaseHit = emergency or physicalBroadPhaseMayHit(
        record,
        localMotion,
        horizon,
        uncertainty
    )
    local contactTime = emergency and 0 or broadPhaseHit
        and physicalContactTime(
            record,
            localMotion,
            horizon,
            uncertainty
        ) or nil
    if record.Model == "Linear" and record.BounceCount == 0
        and contactTime and contactTime <= getPredictionLead(
        threat.Profile,
        threat.TimingKey
    ) + 0.14 then
        local parameters = RaycastParams.new()
        parameters.FilterType = Enum.RaycastFilterType.Exclude
        parameters.FilterDescendantsInstances = {
            record.Object,
            localCharacter,
            record.AttackerCharacter,
        }
        parameters.IgnoreWater = true
        parameters.RespectCanCollide = true
        local target = predictPosition(localMotion, contactTime, true)
        local result = workspace:Raycast(
            record.Center,
            target - record.Center,
            parameters
        )
        if result and result.Distance + record.Radius
            < (target - record.Center).Magnitude then
            contactTime = nil
            emergency = false
        end
    end
    local profile = threat.Profile
    local lead = getPredictionLead(profile, threat.TimingKey)
    threat.AttackerMotion = {
        Position = record.Center,
        PreviousPosition = record.PreviousCenter or record.Center,
        Velocity = record.Velocity,
        ShortVelocity = record.Velocity,
        Acceleration = record.Acceleration,
        PositionJitter = record.PositionJitter,
        VelocityJitter = 0,
        SampleAt = now,
        LastChangedAt = now,
    }
    threat.LookDirection = horizontalUnit(record.Velocity)
    threat.AimDirection = unitOrFallback(record.Velocity)
    threat.CurrentDistance = distance
    threat.ClosingSpeed = closing
    threat.AttackerApproachSpeed = math.max(0, closing)
    threat.AttackerAlignment = closing > 0 and 1 or -1
    threat.EvaluationStart = 0
    threat.EvaluationEnd = horizon
    threat.Uncertainty = uncertainty
    threat.Emergency = emergency
    threat.Confidence = math.max(
        threat.Confidence or 0,
        record.ModelConfidence or 0.35
    )
    threat.ContactIn = contactTime
    threat.ImpactEarliest, threat.ImpactLatest = State:ContactIntervalFor(
        threat,
        contactTime
    )
    threat.CandidateImpactAt = threat.ImpactEarliest
        and now + threat.ImpactEarliest or nil
    threat.Deadline = threat.CandidateImpactAt
        and threat.CandidateImpactAt - lead or math.huge
    threat.LastEvaluatedAt = now
    if contactTime then
        threat.LastConfirmedAt = now
    elseif threat.LastConfirmedAt
        and now - threat.LastConfirmedAt > math.max(0.06, 2 * State.FrameMean) then
        threat.CountedPrediction = false
        threat.FirstConfirmedAt = nil
    end
    if contactTime and not threat.CountedPrediction then
        threat.CountedPrediction = true
        threat.FirstConfirmedAt = os.clock()
        State.PredictedThreats += 1
        pushReplay("physical_contact", now, {
            Signature = record.Signature,
            Model = record.Model,
            Contact = contactTime,
            Confidence = record.ModelConfidence,
        })
    end
    return true
end

local function createPhysicalThreat(record, now, localMotion)
    if record.Threat or record.LocalOwned or not localMotion
        or not record.Center or not record.Velocity then
        return nil
    end
    local relative = record.Center - localMotion.Position
    local distance = relative.Magnitude
    if distance > PROJECTILE_ACQUISITION_RANGE then
        return nil
    end
    local closing = distance > 0.01
        and -relative.Unit:Dot(record.Velocity - localMotion.Velocity) or 0
    local speed = record.Velocity.Magnitude
    local provisional = record.StableSamples < 2
    if provisional then
        local relativeVelocity = record.Velocity - localMotion.Velocity
        local provisionalHorizon = math.min(
            0.5,
            distance / math.max(closing, speed * 0.25, 1) + 0.08
        )
        local entry = speed >= 24 and movingPointCapsuleEntry(
            relative,
            relativeVelocity,
            BODY_HALF_HEIGHT,
            BODY_RADIUS + (record.Radius or 0.5) + 3.5,
            0,
            provisionalHorizon
        ) or nil
        if not entry then
            return nil
        end
    end
    local canTurnOrAccelerate = record.Model == "Bouncing"
        or record.BounceCount > 0
        or record.Signature == "boomerang"
        or record.Model == "Homing"
            and record.StableSamples >= 4
            and record.ModelConfidence >= 0.72
            and record.HomingStrength >= 0.62
        or record.Model == "Curved"
            and record.StableSamples >= 3
            and record.ModelConfidence >= 0.58
        or record.Model == "Accelerating"
            and record.ModelConfidence >= 0.58
            and record.Acceleration.Magnitude > 35
    if speed < 3 and not canTurnOrAccelerate then
        return nil
    end
    if closing < 2 and not canTurnOrAccelerate then
        local relativeVelocity = record.Velocity - localMotion.Velocity
        local speedSquared = relativeVelocity:Dot(relativeVelocity)
        local closestTime = speedSquared > 0.000001 and math.clamp(
            -relative:Dot(relativeVelocity) / speedSquared,
            0,
            0.7
        ) or 0
        local minimumPathDistance = (
            relative + relativeVelocity * closestTime
        ).Magnitude
        if minimumPathDistance > BODY_RADIUS + record.Radius + 4 then
            return nil
        end
    end
    local profile = physicalProfileFor(record)
    local threat = {
        Key = record.Object,
        Track = nil,
        AnimationId = nil,
        Character = record.AttackerCharacter,
        Profile = profile,
        TimingKey = "Physical:" .. record.Signature,
        Confidence = record.ModelConfidence or 0.5,
        Provenance = "PhysicalProjectile",
        PhysicalProjectile = record,
        PhysicalOnly = true,
        ProvisionalProjectile = provisional,
        CreatedAt = now,
        ExpiresAt = record.ExpiresAt,
        InitialDistance = distance,
        PreliminaryDeadline = now
            + distance / math.max(closing, 10)
            - getPredictionLead(profile, "Physical:" .. record.Signature),
        LookDirection = horizontalUnit(record.Velocity),
        AimDirection = unitOrFallback(record.Velocity),
    }
    if addThreat(threat) then
        record.Threat = threat
        State.PhysicalProjectileThreats += 1
        if provisional then
            State.ProvisionalProjectileThreats += 1
            pushReplay("projectile_fast_lane", now, {
                Signature = record.Signature,
                Speed = speed,
                Distance = distance,
            })
        end
        return threat
    end
    return nil
end

local function bindProjectileEffects(generation)
    local currentEffects = workspace:FindFirstChild("Effects")
    if currentEffects == Effects and State.ProjectileEffectsConnection
        and State.ProjectileEffectsConnection.Connected then
        return
    end
    disconnect(State.ProjectileEffectsConnection)
    State.ProjectileEffectsConnection = nil
    Effects = currentEffects
    if not Effects or not State.Enabled or generation ~= State.Generation then
        return
    end
    local initial = Effects:GetChildren()
    for index = 1, math.min(#initial, 192) do
        registerProjectile(initial[index], generation)
    end
    State.NextProjectileRescanAt = os.clock() + 1.5
    State.ProjectileEffectsConnection = Effects.ChildAdded:Connect(guarded(
        "projectile added",
        function(object)
            if State.Enabled and State.Generation == generation then
                registerProjectile(object, generation)
            end
        end
    ))
end

local function sampleProjectiles(now, localMotion)
    if workspace:FindFirstChild("Effects") ~= Effects
        or not State.ProjectileEffectsConnection
        or not State.ProjectileEffectsConnection.Connected then
        bindProjectileEffects(State.Generation)
    end
    for index = #State.ProjectileList, 1, -1 do
        local record = State.ProjectileList[index]
        local valid = now <= record.ExpiresAt
            and record.Object and record.Object.Parent
            and record.Part and record.Part.Parent
            and not hasGunToken(record.Object.Name)
        if valid then
            local shouldSample = true
            if localMotion and record.Center then
                local relative = record.Center - localMotion.Position
                local distance = relative.Magnitude
                local closing = distance > 0.01 and -relative.Unit:Dot(
                    record.Velocity - localMotion.Velocity
                ) or 0
                local urgent = distance <= 100 or closing >= 60
                    or record.Threat and record.Threat.ContactIn ~= nil
                    or record.Model == "Homing"
                shouldSample = urgent or now >= (record.NextSampleAt or 0)
                if shouldSample then
                    record.NextSampleAt = urgent and now or now + 1 / 30
                end
            end
            local ok, sampled = true, true
            if shouldSample then
                -- Quarantine the complete record transaction. One malformed
                -- effect can no longer abort all threat work for this frame.
                ok, sampled = xpcall(function()
                    local updated = sampleProjectileRecord(record, now)
                    if updated then
                        associateProjectile(record, now)
                        createPhysicalThreat(record, now, localMotion)
                    end
                    return updated
                end, debug.traceback)
            end
            valid = ok and sampled
            if ok and sampled then
                record.ErrorCount = 0
            elseif not ok then
                record.ErrorCount = (record.ErrorCount or 0) + 1
                valid = record.ErrorCount < 2
            end
        end
        if not valid then
            removeProjectileAt(index, now)
        end
    end
    if Effects and now >= State.NextProjectileRescanAt then
        State.NextProjectileRescanAt = now + 1.5
        local children = Effects:GetChildren()
        for index = 1, math.min(#children, 96) do
            registerProjectile(children[index], State.Generation)
        end
    end
end

local function startProjectileTracking(generation)
    bindProjectileEffects(generation)
end

local function retireCoveredThreats(now, primary)
    for index = #State.Pending, 1, -1 do
        local threat = State.Pending[index]
        if threat == primary or threat.ExpiresAt <= now then
            removeThreatAt(index)
        end
    end
end

local function restoreDirectionLease(token, fromTask)
    local lease = State.DirectionLease
    if not lease or token and lease.Token ~= token then
        return false
    end
    State.DirectionLease = nil
    local restoreTask = lease.RestoreTask
    lease.RestoreTask = nil
    if restoreTask and not fromTask then
        pcall(task.cancel, restoreTask)
    end

    if lease.ChangedController then
        if rawget(shared, "controllerpressed") == true then
            pcall(
                rawset,
                shared,
                "controllerpressed",
                lease.PreviousControllerPressed
            )
        else
            State.DirectionLeaseConflicts += 1
        end
    end

    local humanoid = lease.Humanoid
    if humanoid and humanoid.Parent
        and LocalPlayer.Character == lease.Character then
        local ok, currentDirection = pcall(function()
            return humanoid.MoveDirection
        end)
        if ok and (currentDirection - lease.ForcedDirection).Magnitude <= 0.2 then
            pcall(
                humanoid.Move,
                humanoid,
                lease.OriginalMoveDirection,
                false
            )
        elseif ok then
            State.DirectionLeaseConflicts += 1
        end
    end
    State.DirectionLeaseRestores += 1
    State.LastDirectionLeaseMs = (os.clock() - lease.BeganAt) * 1000
    return true
end

local function confirmDodgeAttempt(now)
    local attempt = State.AttemptPending
    if not attempt then
        return
    end
    local character = attempt.Character
    if not character or character ~= LocalPlayer.Character then
        if attempt.Telemetry then
            attempt.Telemetry.Rejected = true
        end
        restoreDirectionLease(attempt.LeaseToken, false)
        releaseRequestSlot(attempt.RequestBudgetToken)
        State.AttemptPending = nil
        State.DodgePlan = nil
        State.NextMpcAt = 0
        State.RejectedDodges += 1
        return
    end

    local recentDash = character:GetAttribute("RecentDash")
    local attributeAcknowledged = type(recentDash) == "number"
        and recentDash ~= attempt.BeforeRecentDash
    local phantomStackAcknowledged = false
    if attempt.WasPhantomStep and attempt.BeforePhantomStacks ~= nil then
        local currentStacks, source = State:GetPhantomStackCount(character, now)
        phantomStackAcknowledged = source == "Controller"
            and currentStacks > attempt.BeforePhantomStacks
    end
    local root = character:FindFirstChild("HumanoidRootPart")
    local directionVerified = false
    if root then
        local elapsedSinceRequest = math.max(0.001, now - attempt.RequestedAt)
        local expectedPosition = attempt.StartPosition
            + attempt.BaselineVelocity * elapsedSinceRequest
        local excessDisplacement = root.Position - expectedPosition
        local excessVelocity = root.AssemblyLinearVelocity
            - attempt.BaselineVelocity
        local horizontalDisplacement = Vector3.new(
            excessDisplacement.X,
            0,
            excessDisplacement.Z
        )
        local horizontalVelocity = Vector3.new(
            excessVelocity.X,
            0,
            excessVelocity.Z
        )
        local displacementSpeed = horizontalDisplacement:Dot(attempt.Direction)
            / elapsedSinceRequest
        local velocityAligned = horizontalVelocity.Magnitude > 1
            and horizontalVelocity.Unit:Dot(attempt.Direction) >= 0.82
        local displacementAligned = horizontalDisplacement.Magnitude > 0.05
            and horizontalDisplacement.Unit:Dot(attempt.Direction) >= 0.82
        directionVerified = velocityAligned
                and horizontalVelocity:Dot(attempt.Direction) > 40
            or displacementAligned and displacementSpeed > 40
    end

    if (attributeAcknowledged or directionVerified or phantomStackAcknowledged)
        and not attempt.Acknowledged then
        local startup = math.max(0, now - attempt.RequestedAt)
        local startupError = math.clamp(
            startup - State.DashStartupMean,
            -0.08,
            0.08
        )
        State.DashStartupMean += startupError
            * (startupError > 0 and 0.25 or 0.08)
        State.DashStartupDeviation += (
            math.abs(startupError) - State.DashStartupDeviation
        ) * 0.18
        State.LastAcceptedAt = now
        attempt.Acknowledged = true
        attempt.AcknowledgedAt = now
        attempt.AcknowledgementMilliseconds = math.max(
            0,
            (now - (attempt.ReleaseAt or attempt.RequestedAt)) * 1000
        )
        attempt.AttributeAcknowledged = attributeAcknowledged
        attempt.VerificationExpiresAt = now + math.clamp(
            2 * State.FrameMean,
            0.04,
            0.09
        )
        restoreDirectionLease(attempt.LeaseToken, false)
    end

    local accepted = directionVerified or phantomStackAcknowledged
        or attributeAcknowledged
            and attempt.VerificationExpiresAt
            and now >= attempt.VerificationExpiresAt
    if accepted then
        if attempt.Telemetry then
            attempt.Telemetry.Accepted = true
        end
        State.AcceptedDodges += 1
        attempt.Threat.RequestCount = (attempt.Threat.RequestCount or 0) + 1
        if directionVerified then
            State.DirectionVerifiedDodges += 1
        else
            State.DirectionUnverifiedDodges += 1
        end
        State.LastThreat = attempt.Threat.Profile.Name
        State.LastDirection = attempt.DirectionName
        State.LastContactMilliseconds = math.max(
            0,
            math.floor((attempt.Threat.ContactIn or 0) * 1000 + 0.5)
        )
        State.LastReactionMilliseconds = attempt.ReactionMilliseconds or -1
        State.LastAcknowledgementMilliseconds =
            attempt.AcknowledgementMilliseconds or -1
        pushReplay("dodge_accepted", now, {
            Threat = State.LastThreat,
            Direction = State.LastDirection,
            Verified = directionVerified,
            Reaction = State.LastReactionMilliseconds,
            Ack = State.LastAcknowledgementMilliseconds,
        })
        State.AttemptPending = nil
        State.DodgePlan = nil
        State.NextMpcAt = 0
        State.LastBlockReason = "None"
        if directionVerified then
            retireCoveredThreats(now, attempt.Threat)
        end
        updateStatus(true)
    elseif now >= attempt.ExpiresAt then
        if attempt.Telemetry then
            attempt.Telemetry.Rejected = true
        end
        restoreDirectionLease(attempt.LeaseToken, false)
        releaseRequestSlot(attempt.RequestBudgetToken)
        State.AttemptPending = nil
        State.DodgePlan = nil
        State.NextMpcAt = 0
        State.RejectedDodges += 1
        State.LastBlockReason = "Dash acknowledgement timeout"
        pushReplay("dodge_rejected", now, {
            Threat = attempt.Threat.Profile.Name,
        })
    end
end

function State:PhantomStepDistance(boostValue, multiplier, timeAhead)
    local sprintTier = math.clamp(
        math.floor((tonumber(boostValue) or 0) / 1.5 + 0.5),
        0,
        5
    )
    local tierScale = sprintTier * 0.03 + 1
    local speed = self.PhantomStepDirectionScale
        * self.PhantomStepBaseSpeed * tierScale
        * (tonumber(multiplier) or 1)
    return speed * math.min(
        math.clamp(timeAhead, 0, 0.5),
        self.PhantomStepDuration
    )
end

local function getDashDistance(character, timeAhead)
    local swingSpeed = character:FindFirstChild("SwingSpeed")
    local multiplier = swingSpeed and swingSpeed.Value or 1
    local time = math.clamp(timeAhead, 0, 0.5)

    if State:IsPhantomStepActive(character) then
        -- MoreFunctionsClient.Roll applies this exact short-burst formula:
        -- direction * 7 * (27 * sprint tier scale) * SwingSpeed. Its velocity
        -- driver is destroyed after 0.05 seconds instead of following the
        -- ordinary half-second Bezier decay.
        local boosts = LocalPlayer:FindFirstChild("Boosts")
        local fasterSprint = boosts and boosts:FindFirstChild("Faster Sprint")
        local boostValue = 0
        if fasterSprint then
            local ok, value = pcall(function()
                return fasterSprint.Value
            end)
            if ok and type(value) == "number" then
                boostValue = value
            end
        end
        local analytic = State:PhantomStepDistance(
            boostValue,
            multiplier,
            time
        )
        -- MoreFunctionsClient.Roll writes this exact absolute velocity every
        -- RenderStepped frame and destroys the driver after 0.05 seconds.
        -- Generic position learning is contaminated by the player's restored
        -- movement after that instant, so the exact formula is authoritative.
        return analytic
    end

    local speedBase = character:GetAttribute("WallyWestRun")
        and character:GetAttribute("WallyWestRun") >= 50
        and 200
        or -5
    local initialSpeed = (speedBase * 2.25 + 125) * multiplier
    local tailSpeed = (speedBase + 65) * multiplier
    if time <= 0.1 then
        local analytic = initialSpeed * time
        return State:CalibratedDashDistance(
            State:CurrentDashCalibrationKey(character, false),
            time,
            analytic
        )
    end
    local normalized = (time - 0.1) / 0.4
    local integral = normalized
        - 0.3 * normalized * normalized
        - 0.4 * normalized * normalized * normalized
        + 0.2 * normalized * normalized * normalized * normalized
    local analytic = initialSpeed * 0.1 + tailSpeed * 0.4 * integral
    return State:CalibratedDashDistance(
        State:CurrentDashCalibrationKey(character, false),
        time,
        analytic
    )
end

function State:TerrainDashDistance(character, timeAhead)
    local phantom = self:IsPhantomStepActive(character)
    local analyticOrLower = getDashDistance(character, timeAhead)
    local upper
    if phantom then
        -- The native Phantom controller sets an absolute velocity, rather
        -- than adding momentum, and hard-stops it after 0.05 seconds.  A
        -- small numerical/replication margin is sufficient and avoids the
        -- contaminated 30+ stud envelope that caused coverage-budget vetoes.
        upper = analyticOrLower * self.PhantomTerrainSafetyScale
    else
        upper = self:CalibratedDashUpperDistance(
            self:CurrentDashCalibrationKey(character, false),
            math.clamp(timeAhead, 0, 0.5),
            analyticOrLower
        )
    end
    return upper + self.TerrainTravelMargin
end

function State:TerrainPathVector(character, motion, direction)
    direction = horizontalUnit(direction)
    -- Phantom Step overwrites pre-existing velocity; it does not add it to
    -- the burst.  Ordinary dash distance already includes its full curve.
    return direction * self:TerrainDashDistance(character, 0.5)
end

function State:BuildTerrainParameters(character)
    local filter = { Live }
    local effects = workspace:FindFirstChild("Effects")
    if effects then
        filter[#filter + 1] = effects
    end
    local camera = workspace.CurrentCamera
    if camera then
        filter[#filter + 1] = camera
    end
    local parameters = RaycastParams.new()
    parameters.FilterType = Enum.RaycastFilterType.Exclude
    parameters.FilterDescendantsInstances = filter
    parameters.IgnoreWater = true
    parameters.RespectCanCollide = true
    if character and self:IsPhantomStepActive(character) then
        -- Match the game's real Phantom Step collision matrix.  This keeps
        -- non-colliding decorations out while retaining Default map geometry
        -- and the live invisible Barriers volumes.
        pcall(function()
            parameters.CollisionGroup = "PhantomStepDash"
        end)
    end
    return parameters
end

function State:ControllerDirectionVector(code, cameraLook)
    cameraLook = horizontalUnit(cameraLook)
    local cameraRight = cameraLook:Cross(Vector3.new(0, 1, 0)).Unit
    if code == "Backwards" then
        return -cameraLook
    elseif code == "Right" then
        return cameraRight
    elseif code == "Left" then
        return -cameraRight
    end
    return cameraLook
end

function State:ExecutableDashDirection(cameraLook, requestedDirection)
    cameraLook = horizontalUnit(cameraLook)
    requestedDirection = horizontalUnit(requestedDirection, cameraLook)
    local cameraRight = cameraLook:Cross(Vector3.new(0, 1, 0)).Unit
    local code = "Forward"
    -- This mirrors DashRequest's u142 ordering and thresholds.  The native
    -- controller can only execute these four outcomes; scoring a diagonal or
    -- fine-angle path would validate terrain the real dash never follows.
    if requestedDirection:Dot(cameraRight) > 0.75 then
        code = "Right"
    end
    if requestedDirection:Dot(-cameraRight) > 0.75 then
        code = "Left"
    end
    if requestedDirection:Dot(cameraLook) > 0.6 then
        code = "Forward"
    end
    if requestedDirection:Dot(-cameraLook) > 0.6 then
        code = "Backwards"
    end
    return code, self:ControllerDirectionVector(code, cameraLook)
end

function State:LimitTerrainPath(startPosition, pathVector, parameters)
    local distance = pathVector.Magnitude
    if distance <= 0.001 then
        return ZERO, nil
    end
    local ok, wall = pcall(
        workspace.Spherecast,
        workspace,
        startPosition,
        self.GroundFootprintRadius,
        pathVector,
        parameters
    )
    if not ok then
        wall = workspace:Raycast(startPosition, pathVector, parameters)
    end
    if not wall then
        return pathVector, nil
    end
    local limitedDistance = math.max(0, wall.Distance - 0.15)
    return pathVector.Unit * limitedDistance, wall.Instance
end

function State:IsBarrierGeometry(instance)
    local current = instance
    for _ = 1, 16 do
        if not current or current == workspace then
            break
        end
        if current.Name == "Barriers" then
            return true
        end
        current = current.Parent
    end
    return false
end

function State:IsHazardGeometry(instance)
    local collectionService = game:GetService("CollectionService")
    local current = instance
    for _ = 1, 12 do
        if not current or current == workspace then
            break
        end
        local lowered = string.lower(current.Name)
        for _, signal in ipairs(self.HazardNameSignals) do
            if string.find(lowered, signal, 1, true) then
                return true
            end
        end
        for _, signal in ipairs(self.HazardBooleanSignals) do
            local value = current:GetAttribute(signal)
            if value == true or type(value) == "number" and value > 0 then
                return true
            end
            if collectionService:HasTag(current, signal) then
                return true
            end
        end
        local damage = current:GetAttribute("Damage")
        if type(damage) == "number" and damage > 0 then
            return true
        end
        current = current.Parent
    end
    return false
end

function State:IsWalkableSupport(result, roleCache, minimumNormalY)
    local part = result and result.Instance
    local role = part and roleCache and roleCache[part]
    if part and not role then
        local physical = part:IsA("Terrain")
            or part:IsA("BasePart") and part.CanCollide and part.CanQuery
        local stable = true
        if part:IsA("BasePart") then
            local linearSpeed = part.AssemblyLinearVelocity.Magnitude
            local angularReach = math.min(part.Size.Magnitude * 0.5, 6)
            local surfaceSpeed = linearSpeed
                + part.AssemblyAngularVelocity.Magnitude * angularReach
            stable = surfaceSpeed * self.GroundSupportHorizon
                <= self.MaximumSupportMotion
        end
        role = {
            Physical = physical,
            Stable = stable,
            Barrier = self:IsBarrierGeometry(part),
            Hazard = self:IsHazardGeometry(part),
        }
        if roleCache then
            roleCache[part] = role
        end
    end
    return result ~= nil
        and result.Normal.Y >= (minimumNormalY or self.GroundMinimumNormalY)
        and role and role.Physical and role.Stable
        and not role.Barrier and not role.Hazard,
        role
end

function State:GroundPathSafe(
    startPosition,
    pathVector,
    parameters,
    strictPhantom
)
    if typeof(startPosition) ~= "Vector3"
        or typeof(pathVector) ~= "Vector3" then
        return false, "Invalid path", 0
    end
    local flatPath = Vector3.new(pathVector.X, 0, pathVector.Z)
    local travel = flatPath.Magnitude
    local direction = horizontalUnit(flatPath, Vector3.new(0, 0, -1))
    local lateral = direction:Cross(Vector3.new(0, 1, 0)).Unit
    local radius = self.GroundFootprintRadius
    local railOffsets = { ZERO, lateral * radius, -lateral * radius }
    local baseSpacing = math.max(self.GroundProbeSpacing, 0.5)
    local adaptiveSpacing = math.max(
        baseSpacing,
        travel / math.max(self.MaximumGroundSamples, 1)
    )
    if adaptiveSpacing > self.MaximumAdaptiveGroundSpacing then
        return false, "Ground coverage budget", 0
    end
    local segments = math.clamp(
        math.max(2, math.ceil(travel / adaptiveSpacing)),
        2,
        self.MaximumGroundSamples
    )
    local minimumNormalY = strictPhantom
        and self.PhantomGroundMinimumNormalY
        or self.GroundMinimumNormalY
    local castDirection = Vector3.new(
        0,
        -(self.GroundProbeRise + self.GroundProbeDepth),
        0
    )
    local referenceFloorY
    local previousFloorY
    local minimumSupports = 5
    local supportRoleCache = {}
    for segmentIndex = 0, segments do
        local fraction = segmentIndex / segments
        local point = startPosition + flatPath * fraction
        local centerFloor = workspace:Raycast(
            point + Vector3.new(0, self.GroundProbeRise, 0),
            castDirection,
            parameters
        )
        local centerWalkable, centerRole = self:IsWalkableSupport(
            centerFloor,
            supportRoleCache,
            minimumNormalY
        )
        if not centerWalkable then
            if centerRole and centerRole.Barrier then
                return false, "Barrier is not ground", 0
            elseif centerRole and centerRole.Hazard then
                return false, "Hazardous support", 0
            end
            return false, "Center support missing", 0
        end
        local centerY = centerFloor.Position.Y
        local centerClearance = point.Y - centerY
        if centerClearance < self.MinimumGroundClearance
            or centerClearance > self.MaximumGroundClearance then
            return false, "Support clearance invalid", 1
        end
        referenceFloorY = referenceFloorY or centerY
        if centerY < referenceFloorY - self.MaximumSafeDrop then
            return false, "Unsafe drop", 1
        end
        if previousFloorY
            and math.abs(centerY - previousFloorY) > self.MaximumGroundStep then
            return false, "Abrupt floor change", 1
        end
        previousFloorY = centerY

        local supports = 1
        for offsetIndex = 2, #railOffsets do
            local floor = workspace:Raycast(
                point + railOffsets[offsetIndex]
                    + Vector3.new(0, self.GroundProbeRise, 0),
                castDirection,
                parameters
            )
            local floorClearance = floor and point.Y - floor.Position.Y
            if self:IsWalkableSupport(
                floor,
                supportRoleCache,
                minimumNormalY
            )
                and floorClearance >= self.MinimumGroundClearance
                and floorClearance <= self.MaximumGroundClearance
                and math.abs(floor.Position.Y - centerY)
                    <= self.MaximumGroundStep then
                supports += 1
            end
        end
        if segmentIndex == segments then
            for _, endpointOffset in ipairs({
                direction * radius,
                -direction * radius,
            }) do
                local floor = workspace:Raycast(
                    point + endpointOffset
                        + Vector3.new(0, self.GroundProbeRise, 0),
                    castDirection,
                    parameters
                )
                local floorClearance = floor and point.Y - floor.Position.Y
                if self:IsWalkableSupport(
                    floor,
                    supportRoleCache,
                    minimumNormalY
                )
                    and floorClearance >= self.MinimumGroundClearance
                    and floorClearance <= self.MaximumGroundClearance
                    and math.abs(floor.Position.Y - centerY)
                        <= self.MaximumGroundStep then
                    supports += 1
                end
            end
        end
        minimumSupports = math.min(minimumSupports, supports)
        local required = segmentIndex == segments and 5 or 3
        if supports < required then
            return false,
                segmentIndex == segments
                    and "Landing footprint unsupported"
                    or "Swept footprint unsupported",
                minimumSupports
        end
    end
    return true, "Supported", minimumSupports
end

local function collectDirectionThreats(primary)
    local selected = { primary }
    for _, threat in ipairs(State.Pending) do
        if threat ~= primary and threat.ContactIn then
            local insertAt = #selected + 1
            for index = 2, #selected do
                if threat.Deadline < selected[index].Deadline then
                    insertAt = index
                    break
                end
            end
            if insertAt <= MAX_DIRECTION_THREATS then
                for index = math.min(#selected + 1, MAX_DIRECTION_THREATS), insertAt + 1, -1 do
                    selected[index] = selected[index - 1]
                end
                selected[insertAt] = threat
            end
        end
    end
    while #selected > MAX_DIRECTION_THREATS do
        selected[#selected] = nil
    end
    return selected
end

local function chooseDodgeDirectionLegacy(primary, now, character, humanoid, localRoot)
    local camera = workspace.CurrentCamera
    local cameraLook = camera and horizontalUnit(camera.CFrame.LookVector)
        or horizontalUnit(localRoot.CFrame.LookVector)
    local cameraRight = cameraLook:Cross(Vector3.new(0, 1, 0)).Unit
    local movementDirection = humanoid.MoveDirection
    local maximumTravel = getDashDistance(character, 0.5)
    local threats = collectDirectionThreats(primary)
    local localMotion = State.LocalMotion or newMotion(localRoot, now)

    local filter = { Live }
    local effects = workspace:FindFirstChild("Effects")
    if effects then
        filter[#filter + 1] = effects
    end
    if camera then
        filter[#filter + 1] = camera
    end
    local parameters = RaycastParams.new()
    parameters.FilterType = Enum.RaycastFilterType.Exclude
    parameters.FilterDescendantsInstances = filter
    parameters.IgnoreWater = true
    parameters.RespectCanCollide = true

    local function candidatePosition(direction, travel, timeAhead)
        local startup = math.max(0, State.DashStartupMean)
        if timeAhead <= startup then
            return predictPosition(localMotion, timeAhead, true)
        end
        local startupPosition = predictPosition(localMotion, startup, true)
        local predictedVertical = predictPosition(localMotion, timeAhead, true).Y
        local distance = math.min(
            travel,
            getDashDistance(character, timeAhead - startup)
        )
        return Vector3.new(
            startupPosition.X + direction.X * distance,
            predictedVertical,
            startupPosition.Z + direction.Z * distance
        )
    end

    local bestName = "Backwards"
    local bestDirection = -cameraLook
    local bestScore = -math.huge
    local scoringStarted = os.clock()
    for candidateIndex = 1, 4 do
        local candidateDeadline = scoringStarted + 0.002 * candidateIndex
        local name
        local direction
        if candidateIndex == 1 then
            name = "Forward"
            direction = cameraLook
        elseif candidateIndex == 2 then
            name = "Backwards"
            direction = -cameraLook
        elseif candidateIndex == 3 then
            name = "Right"
            direction = cameraRight
        else
            name = "Left"
            direction = -cameraRight
        end

        local travel = maximumTravel
        local castOk, wall = pcall(
            workspace.Spherecast,
            workspace,
            localRoot.Position,
            1.6,
            direction * maximumTravel,
            parameters
        )
        if not castOk then
            wall = workspace:Raycast(
                localRoot.Position,
                direction * maximumTravel,
                parameters
            )
        end
        if wall then
            travel = math.max(0, wall.Distance - 2)
        end
        local endpoint = localRoot.Position + direction * travel
        local terrainPenalty = 0
        local floorSafe = true
        if movementDirection.Magnitude > 0.1 then
            terrainPenalty += movementDirection.Unit:Dot(direction) * 0.75
        end

        if humanoid.FloorMaterial ~= Enum.Material.Air then
            for floorIndex = 1, 3 do
                local floorPoint = localRoot.Position
                    + direction * travel * floorIndex / 3
                local floor = workspace:Raycast(
                    floorPoint + Vector3.new(0, 3, 0),
                    Vector3.new(0, -10, 0),
                    parameters
                )
                if not floor then
                    floorSafe = false
                    break
                end
            end
        end
        if travel < 4 then
            terrainPenalty -= 2500
        end

        local collisionCount = 0
        local firstCollision = math.huge
        local minimumClearance = math.huge
        for threatIndex, threat in ipairs(threats) do
            if threatIndex > 1 and os.clock() > candidateDeadline then
                break
            end
            local attackerMotion = threat.AttackerMotion
            if attackerMotion then
                local evaluationStart = math.max(
                    0,
                    threat.EvaluationStart or 0
                )
                local evaluationEnd = math.min(
                    MAX_PREDICTION_TIME,
                    math.max(evaluationStart, threat.EvaluationEnd or 0.5)
                )
                local samples = { evaluationStart, evaluationEnd }
                local startup = math.max(0, State.DashStartupMean)
                local boundaries = {
                    startup,
                    startup + 0.1,
                    startup + 0.5,
                }
                if threat.Profile.Kind == "Ranged" then
                    boundaries[#boundaries + 1] = threat.RangedReleaseIn or 0
                end
                for _, boundary in ipairs(boundaries) do
                    if boundary >= evaluationStart
                        and boundary <= evaluationEnd then
                        samples[#samples + 1] = boundary
                    end
                end
                local contact = threat.ContactIn
                if contact and contact >= evaluationStart
                    and contact <= evaluationEnd then
                    samples[#samples + 1] = contact
                end
                for _, fixedTime in ipairs(DIRECTION_SAMPLE_TIMES) do
                    if fixedTime >= evaluationStart
                        and fixedTime <= evaluationEnd then
                        samples[#samples + 1] = fixedTime
                    end
                end
                local initialDashSpeed = getDashDistance(character, 0.04) / 0.04
                local uniformStep = math.clamp(
                    4 / math.max(initialDashSpeed, 1),
                    0.01,
                    0.06
                )
                local uniformEnd = math.min(
                    evaluationEnd,
                    startup + 0.5
                )
                local uniformTime = evaluationStart + uniformStep
                while uniformTime < uniformEnd and #samples < 56 do
                    samples[#samples + 1] = uniformTime
                    uniformTime += uniformStep
                end
                table.sort(samples)

                local previousProjectileTime
                local previousProjectileLocalPosition
                local previousProjectilePosition
                local lastSample = -math.huge
                for _, sampleTime in ipairs(samples) do
                    if sampleTime - lastSample > 0.0005 then
                        lastSample = sampleTime
                        local localPosition = candidatePosition(
                            direction,
                            travel,
                            sampleTime
                        )
                        local attackerPosition = predictPosition(
                            attackerMotion,
                            sampleTime,
                            true,
                            threat.DashAttack
                        )
                        local hit
                        local clearance
                        if threat.Profile.Kind == "Ranged" then
                            hit, clearance = rangedClearanceAt(
                                threat,
                                sampleTime,
                                localPosition,
                                attackerMotion,
                                threat.Uncertainty or 1
                            )
                            local projectilePosition = rangedProjectilePositionAt(
                                threat,
                                sampleTime
                            )
                            if previousProjectileTime
                                and previousProjectileLocalPosition
                                and previousProjectilePosition
                                and projectilePosition
                                and sampleTime > previousProjectileTime then
                                local duration = sampleTime
                                    - previousProjectileTime
                                local relativeStart = previousProjectilePosition
                                    - previousProjectileLocalPosition
                                local relativeVelocity = (
                                    projectilePosition
                                        - previousProjectilePosition
                                        - localPosition
                                        + previousProjectileLocalPosition
                                ) / duration
                                local combinedRadius = BODY_RADIUS
                                    + (threat.Profile.ProjectileRadius or 0.35)
                                    + (threat.Uncertainty or 1)
                                    + math.min(
                                        2,
                                        1550 * duration * duration / 8
                                    )
                                local entry = movingPointCapsuleEntry(
                                    relativeStart,
                                    relativeVelocity,
                                    BODY_HALF_HEIGHT,
                                    combinedRadius,
                                    0,
                                    duration
                                )
                                if entry then
                                    hit = true
                                    firstCollision = math.min(
                                        firstCollision,
                                        previousProjectileTime + entry
                                    )
                                end
                            end
                            if projectilePosition then
                                previousProjectileTime = sampleTime
                                previousProjectileLocalPosition = localPosition
                                previousProjectilePosition = projectilePosition
                            end
                        else
                            clearance = (localPosition - attackerPosition).Magnitude
                                - threat.Profile.Range
                                - BODY_RADIUS
                            hit = attackHitsAt(
                                threat,
                                sampleTime,
                                localMotion,
                                attackerMotion,
                                threat.Uncertainty or 1,
                                localPosition,
                                true
                            )
                        end
                        minimumClearance = math.min(minimumClearance, clearance)
                        if hit then
                            collisionCount += 1
                            firstCollision = math.min(firstCollision, sampleTime)
                        end
                    end
                end
            end
        end
        if minimumClearance == math.huge then
            minimumClearance = 50
        end
        local score
        if collisionCount == 0 then
            score = 1000000
                + minimumClearance * 100
                + travel * 0.5
                + terrainPenalty
        else
            score = math.min(firstCollision, MAX_PREDICTION_TIME) * 10000
                + minimumClearance * 12
                - collisionCount * 10
                + travel * 0.25
                + terrainPenalty
        end
        if not floorSafe then
            score -= 2000000
        end
        if score > bestScore then
            bestScore = score
            bestName = name
            bestDirection = direction
        end
    end
    return bestName, bestDirection
end

local function chooseDodgeDirection(primary, now, character, humanoid, localRoot)
    local camera = workspace.CurrentCamera
    local cameraLook = camera and horizontalUnit(camera.CFrame.LookVector)
        or horizontalUnit(localRoot.CFrame.LookVector)
    local movementDirection = humanoid.MoveDirection
    local localMotion = State.LocalMotion or newMotion(localRoot, now)
    local phantomStep = State:IsPhantomStepActive(character)
    local threats = collectDirectionThreats(primary)
    local candidates = {}

    local function addCandidate(name, direction)
        if #candidates >= MAX_DIRECTION_CANDIDATES then
            return
        end
        name, direction = State:ExecutableDashDirection(
            cameraLook,
            direction
        )
        for _, candidate in ipairs(candidates) do
            if candidate.Direction:Dot(direction) > 0.985 then
                return
            end
        end
        candidates[#candidates + 1] = {
            Name = name,
            Direction = direction,
        }
    end

    local radialNames = {
        "Forward", "Forward Right", "Right", "Back Right",
        "Backwards", "Back Left", "Left", "Forward Left",
    }
    for index = 0, 7 do
        addCandidate(
            radialNames[index + 1],
            rotateHorizontal(cameraLook, -index * math.pi / 4)
        )
    end
    if movementDirection.Magnitude > 0.1 then
        addCandidate("With movement", movementDirection)
        addCandidate("Against movement", -movementDirection)
    end
    for _, threat in ipairs(threats) do
        if #candidates >= MAX_DIRECTION_CANDIDATES then
            break
        end
        local sourceMotion = threat.AttackerMotion
        local incoming = threat.PhysicalProjectile
            and threat.PhysicalProjectile.Velocity
            or sourceMotion and sourceMotion.Velocity
        if incoming and incoming.Magnitude > 1 then
            local travel = horizontalUnit(incoming)
            addCandidate("Threat tangent right", travel:Cross(Vector3.new(0, 1, 0)))
            addCandidate("Threat tangent left", -travel:Cross(Vector3.new(0, 1, 0)))
        end
        if sourceMotion then
            addCandidate(
                "Away from threat",
                localRoot.Position - sourceMotion.Position
            )
        end
    end
    State.LastOptimizerCandidates = #candidates

    local parameters = State:BuildTerrainParameters(character)
    local maximumTravel = getDashDistance(character, 0.5)

    local function candidatePosition(direction, travel, timeAhead)
        local startup = math.max(0, State.DashStartupMean)
        if timeAhead <= startup then
            return predictPosition(localMotion, timeAhead, true)
        end
        local startupPosition = predictPosition(localMotion, startup, true)
        local vertical = predictPosition(localMotion, timeAhead, true).Y
        local distance = math.min(
            travel,
            getDashDistance(character, timeAhead - startup)
        )
        return Vector3.new(
            startupPosition.X + direction.X * distance,
            vertical,
            startupPosition.Z + direction.Z * distance
        )
    end

    local function sampleTimesFor(threat)
        local first = math.max(0, threat.EvaluationStart or 0)
        local last = math.min(
            MAX_PREDICTION_TIME,
            math.max(first, threat.EvaluationEnd or 0.5)
        )
        local values = { first, last }
        local contact = threat.ContactIn
        if contact and contact >= first and contact <= last then
            values[#values + 1] = contact
        end
        local startup = math.max(0, State.DashStartupMean)
        for _, boundary in ipairs({ startup, startup + 0.1, startup + 0.5 }) do
            if boundary >= first and boundary <= last then
                values[#values + 1] = boundary
            end
        end
        if threat.Profile.Kind == "Ranged" then
            local release = threat.RangedReleaseIn or 0
            if release >= first and release <= last then
                values[#values + 1] = release
            end
        end
        for _, fixed in ipairs(DIRECTION_SAMPLE_TIMES) do
            if fixed >= first and fixed <= last then
                values[#values + 1] = fixed
            end
        end
        local uniformCount = 7
        for index = 1, uniformCount - 1 do
            values[#values + 1] = first
                + (last - first) * index / uniformCount
        end
        table.sort(values)
        local unique = {}
        local previous = -math.huge
        for _, value in ipairs(values) do
            if value - previous > 0.0005 then
                unique[#unique + 1] = value
                previous = value
                if #unique >= MAX_DIRECTION_SAMPLES then
                    break
                end
            end
        end
        return unique
    end

    local bestName = "Backwards"
    local bestDirection = -cameraLook
    local bestScore = -math.huge
    for _, candidate in ipairs(candidates) do
        local direction = candidate.Direction
        local travel = maximumTravel
        local castOk, wall = pcall(
            workspace.Spherecast,
            workspace,
            localRoot.Position,
            1.6,
            direction * maximumTravel,
            parameters
        )
        if not castOk then
            wall = workspace:Raycast(
                localRoot.Position,
                direction * maximumTravel,
                parameters
            )
        end
        if wall then
            travel = math.max(0, wall.Distance - 2)
        end

        local terrainPath = State:TerrainPathVector(
            character,
            localMotion,
            direction
        )
        local limitedTerrainPath, terrainObstacle = State:LimitTerrainPath(
            localRoot.Position,
            terrainPath,
            parameters
        )
        local floorSafe = State:GroundPathSafe(
            localRoot.Position,
            limitedTerrainPath,
            parameters,
            phantomStep
        )
        if State:IsPhantomStepActive(character) and terrainObstacle then
            -- Phantom can slide along a wall/barrier after impact; the
            -- shortened centerline is not proof of the deflected path.
            floorSafe = false
        end

        local collisionCount = 0
        local firstCollision = math.huge
        local minimumClearance = math.huge
        local aggregateRisk = 0
        for _, threat in ipairs(threats) do
            local attackerMotion = threat.AttackerMotion
            local times = sampleTimesFor(threat)
            local threatHit = false
            local threatFirst = math.huge
            local threatClearance = math.huge
            local previousTime
            local previousBody
            local previousProjectile
            local previousWeaponBase
            local previousWeaponTip
            for _, sampleTime in ipairs(times) do
                local body = candidatePosition(direction, travel, sampleTime)
                local hit = false
                local clearance = math.huge
                if threat.PhysicalProjectile then
                    local record = threat.PhysicalProjectile
                    local base, tip, radius = physicalSegmentAt(record, sampleTime)
                    if base then
                        clearance = segmentCapsuleClearance(
                            base,
                            tip,
                            body,
                            BODY_RADIUS + radius + (threat.Uncertainty or 0.5)
                        )
                        hit = clearance <= 0
                        if previousTime and previousProjectile then
                            local entry = sweptMovingSegmentCapsuleEntry(
                                previousProjectile.Base,
                                previousProjectile.Tip,
                                base,
                                tip,
                                previousBody,
                                body,
                                BODY_RADIUS + radius
                                    + (threat.Uncertainty or 0.5),
                                sampleTime - previousTime
                            )
                            if entry then
                                hit = true
                                threatFirst = math.min(
                                    threatFirst,
                                    previousTime + entry
                                )
                            end
                        end
                        previousProjectile = { Base = base, Tip = tip }
                    end
                elseif threat.Profile.Kind == "Ranged" then
                    hit, clearance = rangedClearanceAt(
                        threat,
                        sampleTime,
                        body,
                        attackerMotion,
                        threat.Uncertainty or 1
                    )
                    local projectile = rangedProjectilePositionAt(
                        threat,
                        sampleTime
                    )
                    if previousTime and previousProjectile and projectile then
                        local duration = sampleTime - previousTime
                        local relativeStart = previousProjectile - previousBody
                        local relativeVelocity = (
                            projectile - previousProjectile - body + previousBody
                        ) / math.max(duration, 0.0001)
                        local entry = movingPointCapsuleEntry(
                            relativeStart,
                            relativeVelocity,
                            BODY_HALF_HEIGHT,
                            BODY_RADIUS
                                + (threat.Profile.ProjectileRadius or 0.35)
                                + (threat.Uncertainty or 1),
                            0,
                            duration
                        )
                        if entry then
                            hit = true
                            threatFirst = math.min(
                                threatFirst,
                                previousTime + entry
                            )
                        end
                    end
                    previousProjectile = projectile
                elseif attackerMotion then
                    if threat.WeaponSample then
                        local base, tip, radius = weaponSegmentAt(
                            threat,
                            sampleTime,
                            attackerMotion
                        )
                        if base then
                            clearance = segmentCapsuleClearance(
                                base,
                                tip,
                                body,
                                BODY_RADIUS + radius
                                    + (threat.Uncertainty or 1)
                            )
                            hit = clearance <= 0
                            if previousTime and previousWeaponBase then
                                local entry = sweptMovingSegmentCapsuleEntry(
                                    previousWeaponBase,
                                    previousWeaponTip,
                                    base,
                                    tip,
                                    previousBody,
                                    body,
                                    BODY_RADIUS + radius
                                        + (threat.Uncertainty or 1),
                                    sampleTime - previousTime
                                )
                                if entry then
                                    hit = true
                                    threatFirst = math.min(
                                        threatFirst,
                                        previousTime + entry
                                    )
                                end
                            end
                            previousWeaponBase = base
                            previousWeaponTip = tip
                        end
                    end
                    if not threat.WeaponSample or clearance == math.huge then
                        local attackerPosition = predictPosition(
                            attackerMotion,
                            sampleTime,
                            true,
                            threat.DashAttack
                        )
                        clearance = (body - attackerPosition).Magnitude
                            - threat.Profile.Range - BODY_RADIUS
                        hit = attackHitsAt(
                            threat,
                            sampleTime,
                            localMotion,
                            attackerMotion,
                            threat.Uncertainty or 1,
                            body,
                            true
                        )
                    end
                end
                threatClearance = math.min(threatClearance, clearance)
                if hit then
                    threatHit = true
                    threatFirst = math.min(threatFirst, sampleTime)
                end
                previousTime = sampleTime
                previousBody = body
            end
            if threatHit then
                collisionCount += 1
                firstCollision = math.min(firstCollision, threatFirst)
            end
            minimumClearance = math.min(minimumClearance, threatClearance)
            local urgency = 1 / math.max(
                threat.ContactIn or MAX_PREDICTION_TIME,
                0.035
            )
            aggregateRisk += urgency
                * math.max(0, 4 - math.min(threatClearance, 4))
        end

        if minimumClearance == math.huge then
            minimumClearance = 50
        end
        local movementAlignment = movementDirection.Magnitude > 0.1
            and movementDirection.Unit:Dot(direction) or 0
        local score
        if not floorSafe then
            score = -1000000000 + travel
        elseif collisionCount == 0 then
            score = 100000000
                + minimumClearance * 1000
                - aggregateRisk * 20
                + travel * 2
                + movementAlignment * 3
        else
            score = math.min(firstCollision, MAX_PREDICTION_TIME) * 1000000
                - collisionCount * 10000
                + minimumClearance * 100
                - aggregateRisk * 25
                + travel
        end
        if travel < 4 then
            score -= 200000
        end
        if score > bestScore then
            bestScore = score
            bestName = candidate.Name
            bestDirection = direction
        end
    end
    return bestName, bestDirection
end

function State:IntentRawWeight(threat, hypothesisIndex)
    local motion = threat.AttackerMotion
    local maneuver = motion and motion.ManeuverScore or 0
    local intent = motion and motion.Intent or "Continue"
    local first = 0.58 - 0.25 * maneuver
    local second = 0.12 + 0.08 * maneuver
    local third = second
    local fourth = 0.09 + 0.045 * maneuver
    local fifth = fourth
    if intent == "Brake" then
        fourth += 0.18
        first -= 0.1
    elseif intent == "Turn Left" then
        second += 0.14
        first -= 0.07
    elseif intent == "Turn Right" then
        third += 0.14
        first -= 0.07
    elseif intent == "Burst" or threat.DashAttack then
        fifth += 0.18
        first -= 0.08
    elseif intent == "Continue" then
        first += 0.08
    end
    first = math.max(0.025, first)
    second = math.max(0.025, second)
    third = math.max(0.025, third)
    fourth = math.max(0.025, fourth)
    fifth = math.max(0.025, fifth)
    local total = first + second + third + fourth + fifth
    local selected = hypothesisIndex == 1 and first
        or hypothesisIndex == 2 and second
        or hypothesisIndex == 3 and third
        or hypothesisIndex == 4 and fourth
        or fifth
    return selected / math.max(total, 0.001)
end

function State:IntentHypothesisCount(threat)
    if threat.PhysicalProjectile or threat.RangedReleased
        or (threat.ContactIn or 1) < 0.08 then
        return 1
    end
    local motion = threat.AttackerMotion
    local maneuver = motion and motion.ManeuverScore or 0
    if State.DecayingWorstWork > 0.006 or State.FrameMean > 1 / 45 then
        return 3
    end
    if maneuver < 0.2 and not threat.DashAttack then
        return 3
    end
    return MAX_PATH_HYPOTHESES
end

local function reachableHypothesisAt(threat, timeAhead, hypothesisIndex)
    local motion = threat.AttackerMotion
    if not motion or threat.PhysicalProjectile or threat.RangedReleased
        or timeAhead < 0.08 then
        return ZERO, 0, 1, "Observed"
    end
    State.IntentEnsembleEvaluations += 1
    local weight = State:IntentRawWeight(threat, hypothesisIndex)
    local look = horizontalUnit(
        threat.LookDirection,
        horizontalUnit(motion.Velocity)
    )
    local right = look:Cross(Vector3.new(0, 1, 0))
    if right.Magnitude < 0.001 then
        right = Vector3.new(1, 0, 0)
    else
        right = right.Unit
    end
    local maneuver = motion.ManeuverScore or 0
    local basePadding = 0.2 + 0.55 * maneuver
        + math.min(0.8, (motion.PositionJitter or 0) * 0.35)
    if hypothesisIndex == 1 then
        return ZERO, basePadding, weight, "Continue"
    end

    local lateralAcceleration = math.clamp(
        24 + 4 * (motion.VelocityJitter or 0)
            + 32 * maneuver
            + (threat.DashAttack and 40 or 0),
        24,
        140
    )
    local lateralBound = math.min(
        9,
        0.5 * lateralAcceleration * timeAhead * timeAhead
    )
    if hypothesisIndex == 2 or hypothesisIndex == 3 then
        local sign = hypothesisIndex == 2 and -1 or 1
        local yawBias = math.clamp(
            (motion.HeadingRate or 0) * timeAhead * 0.35,
            -0.7,
            0.7
        )
        local biased = lateralBound * math.clamp(
            1 + (hypothesisIndex == 2 and yawBias or -yawBias),
            0.45,
            1.55
        )
        return right * sign * biased,
            basePadding + 0.22 * lateralBound,
            weight,
            hypothesisIndex == 2 and "Strafe Left" or "Strafe Right"
    end

    local flatVelocity = Vector3.new(
        motion.Velocity.X,
        0,
        motion.Velocity.Z
    )
    local speed = flatVelocity.Magnitude
    if hypothesisIndex == 4 then
        if speed < 1 then
            return ZERO, basePadding + 0.5, weight, "Brake"
        end
        local deceleration = math.clamp(
            90 + math.max(0, -(motion.SpeedTrend or 0)) * 0.35,
            70,
            240
        )
        local brakingTime = math.min(timeAhead, speed / deceleration)
        local brakingDistance = speed * brakingTime
            - 0.5 * deceleration * brakingTime * brakingTime
        local nominalDisplacement = flatVelocity * timeAhead
        local brakingDisplacement = flatVelocity.Unit * brakingDistance
        return clampMagnitude(
            brakingDisplacement - nominalDisplacement,
            12
        ), basePadding + 0.65, weight, "Brake"
    end

    local targetDirection = horizontalUnit(
        threat.TargetDirection or look,
        look
    )
    local turnTime = math.clamp(
        0.24 - 0.1 * maneuver,
        0.1,
        0.24
    )
    local turnBlend = math.clamp(timeAhead / turnTime, 0, 1)
    local targetSpeed = math.max(
        speed,
        threat.DashAttack and 105 or speed + 18
    )
    local desiredDisplacement = flatVelocity:Lerp(
        targetDirection * targetSpeed,
        0.5 * turnBlend
    ) * timeAhead
        + targetDirection * math.min(
            7,
            0.5 * (threat.DashAttack and 130 or 55)
                * timeAhead * timeAhead
        )
    return clampMagnitude(
        desiredDisplacement - flatVelocity * timeAhead,
        12
    ), basePadding + 0.8, weight, "Turn To Target"
end

local function mpcThreatGeometryAt(
    threat,
    timeAhead,
    body,
    hypothesisIndex
)
    local uncertainty = threat.Uncertainty or 0.75
    if threat.PhysicalProjectile then
        local record = threat.PhysicalProjectile
        local base, tip, radius = physicalSegmentAt(record, timeAhead, body)
        if base then
            radius += uncertainty + projectileUncertaintyAt(record, timeAhead)
            return base, tip, radius,
                segmentCapsuleClearance(
                    base,
                    tip,
                    body,
                    BODY_RADIUS + radius
                ), 1, "Observed projectile"
        end
        return nil, nil, nil, math.huge, 1, "Observed projectile"
    end

    local attackerMotion = threat.AttackerMotion
    if threat.Profile.Kind == "Ranged" then
        local projectile = rangedProjectilePositionAt(threat, timeAhead)
        if projectile then
            local radius = (threat.Profile.ProjectileRadius or 0.35)
                + uncertainty
            return projectile, projectile, radius,
                segmentCapsuleClearance(
                    projectile,
                    projectile,
                    body,
                    BODY_RADIUS + radius
                ), 1, "Observed projectile"
        end
        local hit, clearance = rangedClearanceAt(
            threat,
            timeAhead,
            body,
            attackerMotion,
            uncertainty
        )
        return nil, nil, nil, hit and math.min(clearance, 0) or clearance,
            1, "Analytic projectile"
    end
    if not attackerMotion then
        return nil, nil, nil, math.huge, 1, "Unavailable"
    end

    local offset, pathPadding, pathWeight, pathName = reachableHypothesisAt(
        threat,
        timeAhead,
        hypothesisIndex
    )
    if threat.WeaponSample then
        local base, tip, radius = weaponSegmentAt(
            threat,
            timeAhead,
            attackerMotion,
            offset
        )
        local obbBase, obbTip, obbRadius = weaponObbSegmentAt(
            threat,
            timeAhead,
            attackerMotion,
            offset
        )
        local chosenBase = base
        local chosenTip = tip
        local chosenRadius = radius
        local clearance = math.huge
        if base then
            chosenRadius = radius + uncertainty + pathPadding
            clearance = segmentCapsuleClearance(
                base,
                tip,
                body,
                BODY_RADIUS + chosenRadius
            )
        end
        if obbBase then
            local expanded = obbRadius + uncertainty + pathPadding
            local obbClearance = segmentCapsuleClearance(
                obbBase,
                obbTip,
                body,
                BODY_RADIUS + expanded
            )
            if obbClearance < clearance then
                chosenBase = obbBase
                chosenTip = obbTip
                chosenRadius = expanded
                clearance = obbClearance
            end
        end
        if chosenBase then
            return chosenBase, chosenTip, chosenRadius, clearance,
                pathWeight, pathName
        end
    end

    local attackerPosition = predictPosition(
        attackerMotion,
        timeAhead,
        true,
        threat.DashAttack
    ) + offset
    if threat.Profile.Kind == "Area" then
        local radius = threat.Profile.Radius + uncertainty + pathPadding
        return attackerPosition, attackerPosition, radius,
            segmentCapsuleClearance(
                attackerPosition,
                attackerPosition,
                body,
                BODY_RADIUS + radius
            ), pathWeight, pathName
    end

    -- Unsampled melee used to become a 360-degree sphere in MPC, so an
    -- unrelated attacker behind the player could steer the chosen dodge.
    -- Preserve the real forward swing arc here as well as in contact tests.
    local direction = meleeArcDirection(
        threat.Profile,
        attackerPosition,
        threat.LookDirection,
        body
    )
    if threat.Profile.TravelHitbox == true and threat.DashAttack then
        direction = horizontalUnit(attackerMotion.ShortVelocity, direction)
    end
    local base = attackerPosition
        + direction * (threat.Profile.NearReach or 0)
    local tip = attackerPosition
        + direction * (threat.Profile.FarReach or threat.Profile.Range)
    local radius = (threat.Profile.Radius or 0)
        + uncertainty + pathPadding
    return base, tip, radius,
        segmentCapsuleClearance(
            base,
            tip,
            body,
            BODY_RADIUS + radius
        ), pathWeight, pathName
end

local function chooseDodgePlan(primary, now, character, humanoid, localRoot, fastMode)
    local solverStarted = os.clock()
    local dynamicBudget = math.clamp(
        State.FrameMean * 0.18,
        0.0018,
        0.0032
    )
    local solverDeadline = solverStarted
        + math.min(MPC_WORK_BUDGET, dynamicBudget)
    if State.FrameDeadline > solverStarted then
        solverDeadline = math.min(solverDeadline, State.FrameDeadline)
    end
    State.LastIntentModel = primary.IntentModel
        or primary.AttackerMotion and primary.AttackerMotion.Intent
        or "Continue"
    State.LastIntentConfidence = primary.IntentConfidence
        or primary.AttackerMotion and primary.AttackerMotion.IntentConfidence
        or 0.35
    State.LastImpactEarliest = primary.ImpactEarliest or -1
    State.LastImpactLatest = primary.ImpactLatest or -1
    State.LastEnvelopeComplete = true
    State.LastPathHypotheses = 1
    local camera = workspace.CurrentCamera
    local cameraLook = camera and horizontalUnit(camera.CFrame.LookVector)
        or horizontalUnit(localRoot.CFrame.LookVector)
    local movementDirection = humanoid.MoveDirection
    local localMotion = State.LocalMotion or newMotion(localRoot, now)
    local phantomStep = State:IsPhantomStepActive(character)
    local threats = collectDirectionThreats(primary)
    local directions = {}

    local function addDirection(name, direction)
        if #directions >= MAX_DIRECTION_CANDIDATES then
            return
        end
        name, direction = State:ExecutableDashDirection(
            cameraLook,
            direction
        )
        for _, candidate in ipairs(directions) do
            if candidate.Direction:Dot(direction) > 0.985 then
                return
            end
        end
        directions[#directions + 1] = {
            Name = name,
            Direction = direction,
            ControllerDirection = name,
        }
    end

    local radialNames = {
        "Forward", "Forward Right", "Right", "Back Right",
        "Backwards", "Back Left", "Left", "Forward Left",
    }
    for index = 0, 7 do
        addDirection(
            radialNames[index + 1],
            rotateHorizontal(cameraLook, -index * math.pi / 4)
        )
    end
    if movementDirection.Magnitude > 0.1 then
        addDirection("With movement", movementDirection)
        addDirection("Against movement", -movementDirection)
    end
    local sourceMotion = primary.AttackerMotion
    local incoming = primary.PhysicalProjectile
        and primary.PhysicalProjectile.Velocity
        or sourceMotion and sourceMotion.Velocity
    if incoming and incoming.Magnitude > 1 then
        local incomingFlat = horizontalUnit(incoming)
        addDirection(
            "Threat tangent right",
            incomingFlat:Cross(Vector3.new(0, 1, 0))
        )
        addDirection(
            "Threat tangent left",
            -incomingFlat:Cross(Vector3.new(0, 1, 0))
        )
    end
    State.LastOptimizerCandidates = #directions

    local frameGuard = math.max(
        State.FrameMean + 2 * State.FrameDeviation,
        1 / 120
    )
    local latestSafe = math.clamp(
        (primary.Deadline or now) - now - frameGuard,
        0,
        MPC_MAX_DELAY
    )
    local frameQuantum = math.max(State.FrameMean, 1 / 240)
    local delays = {}
    local function addDelay(value)
        value = math.clamp(value or 0, 0, latestSafe)
        -- Never round a request past the latest safe activation boundary.
        value = math.floor(value / frameQuantum) * frameQuantum
        value = math.min(value, latestSafe)
        for _, existing in ipairs(delays) do
            if math.abs(existing - value) < frameQuantum * 0.45 then
                return
            end
        end
        if #delays < MAX_MPC_DELAYS then
            delays[#delays + 1] = value
        end
    end
    addDelay(0)
    if not primary.Emergency then
        addDelay(latestSafe)
        addDelay(math.max(
            0,
            (primary.ContactIn or 0) - State.DashStartupMean - 0.12
        ))
        local second = threats[2]
        addDelay(second and math.max(
            0,
            (second.ContactIn or 0) - State.DashStartupMean - 0.12
        ) or latestSafe * 0.5)
        addDelay(latestSafe * 0.5)
    end
    table.sort(delays)
    State.LastMpcDelayCandidates = #delays
    State.LastMpcLatestDelay = latestSafe

    local dashDistanceCache = {}
    local function dashDistanceAt(timeAhead)
        local key = math.floor(math.clamp(timeAhead, 0, 0.5) * 10000 + 0.5)
        local cached = dashDistanceCache[key]
        if cached == nil then
            cached = getDashDistance(character, timeAhead)
            dashDistanceCache[key] = cached
        end
        return cached
    end
    local maximumTravel = dashDistanceAt(0.5)
    local function bodyAt(direction, travel, delay, timeAhead)
        local onset = delay + math.max(0, State.DashStartupMean)
        if timeAhead <= onset then
            return predictPosition(localMotion, timeAhead, true)
        end
        local onsetPosition = predictPosition(localMotion, onset, true)
        local vertical = predictPosition(localMotion, timeAhead, true).Y
        local distance = math.min(
            travel,
            dashDistanceAt(timeAhead - onset)
        )
        return Vector3.new(
            onsetPosition.X + direction.X * distance,
            vertical,
            onsetPosition.Z + direction.Z * distance
        )
    end

    local function sampleTimes(threat, delay, coarse)
        local first = math.max(0, threat.EvaluationStart or 0)
        local last = math.min(
            MAX_PREDICTION_TIME,
            math.max(first, threat.EvaluationEnd or 0.5)
        )
        local onset = delay + math.max(0, State.DashStartupMean)
        local values = {
            first,
            last,
            math.clamp(threat.ContactIn or first, first, last),
        }
        for _, boundary in ipairs({
            threat.ImpactEarliest,
            threat.ImpactLatest,
        }) do
            if type(boundary) == "number"
                and boundary >= first and boundary <= last then
                values[#values + 1] = boundary
            end
        end
        if not coarse then
            for _, value in ipairs({
                onset,
                onset + 0.1,
                onset + 0.5,
                threat.RangedReleaseIn,
                math.min(POST_DODGE_HORIZON, last),
            }) do
                if type(value) == "number" and value >= first and value <= last then
                    values[#values + 1] = value
                end
            end
            for _, fixed in ipairs(DIRECTION_SAMPLE_TIMES) do
                if fixed >= first and fixed <= last then
                    values[#values + 1] = fixed
                end
            end
            for index = 1, 5 do
                values[#values + 1] = first + (last - first) * index / 6
            end
        end
        table.sort(values)
        local unique = {}
        local previous = -math.huge
        for _, value in ipairs(values) do
            if value - previous > 0.0005 then
                unique[#unique + 1] = value
                previous = value
                if #unique >= (coarse and 3 or MAX_MPC_SAMPLES) then
                    break
                end
            end
        end
        return unique
    end

    -- The same threat/delay grid is evaluated for every direction. Cache it
    -- once per solve so sustained multi-threat combat does not create a large
    -- stream of short-lived tables for the garbage collector.
    local sampleCache = setmetatable({}, { __mode = "k" })
    local function cachedSampleTimes(threat, delay, coarse)
        local row = sampleCache[threat]
        if not row then
            row = {}
            sampleCache[threat] = row
        end
        local key = (coarse and "C" or "F")
            .. tostring(math.floor(delay * 10000 + 0.5))
        local values = row[key]
        if not values then
            values = sampleTimes(threat, delay, coarse)
            row[key] = values
        end
        return values
    end

    local controls = {}
    local tests = 0
    for _, directionCandidate in ipairs(directions) do
        for _, delay in ipairs(delays) do
            local minimumClearance = math.huge
            local hits = 0
            for threatIndex = 1, math.min(3, #threats) do
                local threat = threats[threatIndex]
                local threatHit = false
                for _, sampleTime in ipairs(cachedSampleTimes(
                    threat,
                    delay,
                    true
                )) do
                    local body = bodyAt(
                        directionCandidate.Direction,
                        maximumTravel,
                        delay,
                        sampleTime
                    )
                    local _, _, _, clearance = mpcThreatGeometryAt(
                        threat,
                        sampleTime,
                        body,
                        1
                    )
                    tests += 1
                    minimumClearance = math.min(minimumClearance, clearance)
                    threatHit = threatHit or clearance <= 0
                end
                if threatHit then
                    hits += 1
                end
            end
            controls[#controls + 1] = {
                Name = directionCandidate.Name,
                Direction = directionCandidate.Direction,
                ControllerDirection = directionCandidate.ControllerDirection,
                Delay = delay,
                CoarseHits = hits,
                CoarseClearance = minimumClearance,
                CoarseScore = -hits * 100000
                    + math.min(minimumClearance, 50) * 100
                    + delay,
            }
        end
    end
    table.sort(controls, function(first, secondControl)
        return first.CoarseScore > secondControl.CoarseScore
    end)
    local parameters = State:BuildTerrainParameters(character)
    local terrainHeadingCache = {}
    local terrainHeadingsChecked = 0
    local minimumTerrainHeadings = fastMode and 2 or 1
    for _, control in ipairs(controls) do
        local terrain = terrainHeadingCache[control.ControllerDirection]
        if not terrain then
            if terrainHeadingsChecked >= minimumTerrainHeadings
                and os.clock() >= solverDeadline then
                terrain = {
                    Safe = false,
                    Reason = "Planner terrain budget",
                    Supports = 0,
                }
            else
                local path = State:TerrainPathVector(
                    character,
                    localMotion,
                    control.Direction
                )
                local limitedPath, obstacle = State:LimitTerrainPath(
                    localRoot.Position,
                    path,
                    parameters
                )
                local terrainSafe, terrainReason, terrainSupports
                if phantomStep and obstacle then
                    terrainSafe = false
                    terrainReason = State:IsBarrierGeometry(obstacle)
                        and "Barrier obstructs Phantom path"
                        or "Obstacle obstructs Phantom path"
                    terrainSupports = 0
                else
                    terrainSafe, terrainReason, terrainSupports =
                        State:GroundPathSafe(
                            localRoot.Position,
                            limitedPath,
                            parameters,
                            phantomStep
                        )
                end
                terrain = {
                    Safe = terrainSafe,
                    Reason = terrainReason,
                    Supports = terrainSupports,
                }
                terrainHeadingsChecked += 1
            end
            terrainHeadingCache[control.ControllerDirection] = terrain
        end
        control.CoarseTerrainSafe = terrain.Safe
        control.CoarseTerrainReason = terrain.Reason
        control.CoarseTerrainSupports = terrain.Supports
        control.CoarseScore += terrain.Safe and 100000000 or -100000000
    end
    State.LastOptimizerCandidates = #directions
    table.sort(controls, function(first, secondControl)
        return first.CoarseScore > secondControl.CoarseScore
    end)

    local best
    local safePlanFound = false
    local robustCount = math.min(MAX_MPC_SHORTLIST, #controls)
    if fastMode then
        robustCount = math.min(2, robustCount)
    end
    if State.DecayingWorstWork > 0.006 or State.FrameMean > 1 / 45 then
        robustCount = math.min(4, robustCount)
    end
    for controlIndex = 1, robustCount do
        local control = controls[controlIndex]
        local direction = control.Direction
        local delay = control.Delay
        local onsetPosition = predictPosition(
            localMotion,
            delay + State.DashStartupMean,
            true
        )
        local travel = maximumTravel
        local ok, wall = pcall(
            workspace.Spherecast,
            workspace,
            onsetPosition,
            1.6,
            direction * maximumTravel,
            parameters
        )
        if not ok then
            wall = workspace:Raycast(
                onsetPosition,
                direction * maximumTravel,
                parameters
            )
        end
        if wall then
            travel = math.max(0, wall.Distance - 2)
        end
        -- Terrain does not depend on the weapon hypothesis or MPC delay.
        -- Reuse the one current-frame sweep for this native heading; a fresh
        -- act-time preflight below is the authority if the player, camera, or
        -- map moves before a delayed request fires.
        local cachedTerrain = terrainHeadingCache[control.ControllerDirection]
        local floorSafe = cachedTerrain and cachedTerrain.Safe
        local terrainReason = cachedTerrain and cachedTerrain.Reason
        local terrainSupports = cachedTerrain and cachedTerrain.Supports

        local hitScenarios = 0
        local earliestHit = math.huge
        local worstClearance = math.huge
        local aggregateRisk = 0
        local tailRisk = 0
        local budgetExpired = false
        for _, threat in ipairs(threats) do
            local singlePath = threat.PhysicalProjectile ~= nil
                or threat.RangedReleased
                or (threat.ContactIn or 1) < 0.08
            local hypothesisCount = singlePath and 1
                or State:IntentHypothesisCount(threat)
            if fastMode then
                hypothesisCount = 1
            end
            State.LastPathHypotheses = math.max(
                State.LastPathHypotheses,
                hypothesisCount
            )
            local times = cachedSampleTimes(threat, delay, false)
            for hypothesisIndex = 1, hypothesisCount do
                local scenarioWeight = hypothesisCount == 1 and 1
                    or State:IntentRawWeight(threat, hypothesisIndex)
                local scenarioHit = false
                local scenarioClearance = math.huge
                local previousTime
                local previousBody
                local previousBase
                local previousTip
                local previousRadius
                for _, sampleTime in ipairs(times) do
                    local body = bodyAt(direction, travel, delay, sampleTime)
                    local base, tip, radius, clearance = mpcThreatGeometryAt(
                        threat,
                        sampleTime,
                        body,
                        hypothesisIndex
                    )
                    tests += 1
                    scenarioClearance = math.min(scenarioClearance, clearance)
                    if clearance <= 0 then
                        scenarioHit = true
                        earliestHit = math.min(earliestHit, sampleTime)
                    end
                    if previousTime and previousBase and base then
                        local entry = sweptMovingSegmentCapsuleEntry(
                            previousBase,
                            previousTip,
                            base,
                            tip,
                            previousBody,
                            body,
                            BODY_RADIUS + math.max(
                                previousRadius or 0,
                                radius or 0
                            ),
                            sampleTime - previousTime
                        )
                        tests += 1
                        if entry then
                            scenarioHit = true
                            earliestHit = math.min(
                                earliestHit,
                                previousTime + entry
                            )
                        end
                    end
                    previousTime = sampleTime
                    previousBody = body
                    previousBase = base
                    previousTip = tip
                    previousRadius = radius
                    if tests % 8 == 0 and (
                        tests >= MAX_MPC_TESTS
                        or os.clock() >= solverDeadline
                    ) then
                        budgetExpired = true
                        break
                    end
                end
                if scenarioHit then
                    hitScenarios += 1
                end
                worstClearance = math.min(worstClearance, scenarioClearance)
                local urgency = 1 / math.max(
                    threat.ImpactEarliest or threat.ContactIn or 1,
                    0.05
                )
                local scenarioRisk = urgency
                    * math.max(0, 4 - math.min(scenarioClearance, 4)) ^ 2
                aggregateRisk += scenarioWeight * scenarioRisk
                tailRisk = math.max(tailRisk, scenarioRisk)
                if budgetExpired then
                    break
                end
            end
            if budgetExpired then
                break
            end
        end
        if budgetExpired then
            State.MpcBudgetAborts += 1
            State.EnvelopeBudgetFallbacks += 1
            State.LastEnvelopeComplete = false
            tailRisk = math.max(tailRisk, 1000)
        end
        if worstClearance == math.huge then
            worstClearance = control.CoarseClearance
        end
        local movementAlignment = movementDirection.Magnitude > 0.1
            and movementDirection.Unit:Dot(direction) or 0
        local completedEvaluation = not budgetExpired
        local score = (floorSafe and completedEvaluation and 1 or 0)
                * 1000000000
            - hitScenarios * 10000000
            + (earliestHit == math.huge and MAX_PREDICTION_TIME
                or earliestHit) * 100000
            + math.min(worstClearance, 50) * 1000
            - aggregateRisk * 20
            - tailRisk * 35
            + travel * 2
            + movementAlignment * 3
            + delay
        if travel < 4 then
            score -= 2000000
        end
        local safe = completedEvaluation and floorSafe
            and hitScenarios == 0 and travel >= 4
        safePlanFound = safePlanFound or safe
        if not best or score > best.Score then
            local confidence = math.clamp(
                0.45
                    + 0.3 * math.clamp(worstClearance / 10, 0, 1)
                    + 0.2 * (primary.Confidence or 0.75)
                    - (budgetExpired and 0.15 or 0),
                0.2,
                0.99
            )
            best = {
                Generation = State.Generation,
                Threat = primary,
                CameraLook = cameraLook,
                PlannedRootPosition = localRoot.Position,
                Name = control.Name,
                Direction = direction,
                ControllerDirection = control.ControllerDirection,
                Delay = delay,
                RequestAt = now + delay,
                Deadline = primary.Deadline,
                Score = score,
                Safe = safe,
                TerrainSafe = floorSafe,
                TerrainReason = terrainReason,
                TerrainSupports = terrainSupports,
                Confidence = confidence,
                WorstClearance = worstClearance,
                TailRisk = tailRisk,
                EnvelopeComplete = completedEvaluation,
                Tests = tests,
            }
        end
    end

    if best and not safePlanFound and best.Delay > 0 then
        for _, control in ipairs(controls) do
            if control.Delay <= 0.0005
                and control.CoarseTerrainSafe == true then
                best = {
                    Generation = State.Generation,
                    Threat = primary,
                    CameraLook = cameraLook,
                    PlannedRootPosition = localRoot.Position,
                    Name = control.Name,
                    Direction = control.Direction,
                    ControllerDirection = control.ControllerDirection,
                    Delay = 0,
                    RequestAt = now,
                    Deadline = primary.Deadline,
                    Score = control.CoarseScore,
                    Safe = false,
                    TerrainSafe = true,
                    TerrainReason = control.CoarseTerrainReason,
                    TerrainSupports = control.CoarseTerrainSupports,
                    Confidence = 0.35,
                    WorstClearance = control.CoarseClearance,
                    TailRisk = 1000,
                    EnvelopeComplete = false,
                    Tests = tests,
                }
                break
            end
        end
    end
    State.LastMpcTests = tests
    State.LastMpcMilliseconds = (os.clock() - solverStarted) * 1000
    if best then
        State.LastActivationDelay = best.Delay
        State.LastPlanConfidence = best.Confidence
        State.LastTailRisk = math.clamp(
            1 - math.exp(-(best.TailRisk or 0) / 80),
            0,
            1
        )
        State.LastEnvelopeComplete = best.EnvelopeComplete == true
        State.LastTerrainStatus = best.TerrainSafe
            and "Supported"
            or best.TerrainReason or "Unverified"
    end
    return best
end

local function reserveRequestSlot(now)
    local requestTimes = State.RequestTimes
    local writeIndex = 1
    for readIndex = 1, #requestTimes do
        local requestAt = requestTimes[readIndex]
        if now - requestAt < REQUEST_BUDGET_WINDOW then
            requestTimes[writeIndex] = requestAt
            writeIndex += 1
        end
    end
    for index = #requestTimes, writeIndex, -1 do
        requestTimes[index] = nil
    end
    if #requestTimes >= MAX_REQUESTS_PER_WINDOW then
        State.LastBlockReason = "Request safety budget"
        return nil
    end
    requestTimes[#requestTimes + 1] = now
    return now
end

releaseRequestSlot = function(token)
    if not token then
        return false
    end
    for index = #State.RequestTimes, 1, -1 do
        if State.RequestTimes[index] == token then
            table.remove(State.RequestTimes, index)
            State.RequestBudgetRollbacks += 1
            return true
        end
    end
    return false
end

function State:IsDashVelocityMover(object)
    return object and (
        object:IsA("BodyVelocity")
        or object:IsA("LinearVelocity")
    )
end

function State:FindNewDashVelocityMover(root, existing)
    if not root then
        return nil
    end
    for _, child in ipairs(root:GetChildren()) do
        if self:IsDashVelocityMover(child) and not existing[child] then
            return child
        end
    end
    return nil
end

function State:DashFlingReason(
    safety,
    velocity,
    angularVelocity,
    position,
    now
)
    if not safety then
        return nil
    end
    local horizontal = Vector3.new(velocity.X, 0, velocity.Z)
    local horizontalSpeed = horizontal.Magnitude
    local expectedPeak = math.max(safety.ExpectedPeakSpeed or 0, 1)
    local maximumHorizontal = expectedPeak * self.FlingHorizontalFactor
        + self.FlingHorizontalMargin
    if math.abs(velocity.Y) > self.FlingVerticalLimit then
        return "vertical launch"
    end
    if angularVelocity.Magnitude > self.FlingAngularLimit then
        return "physics spin"
    end
    if horizontalSpeed > maximumHorizontal then
        return "horizontal overspeed"
    end
    -- Phantom Step recalculates its direction from the live camera on every
    -- RenderStepped frame.  A valid native dash can therefore be sideways to
    -- the plan captured a few milliseconds earlier.  Direction mismatch is
    -- not a fling signal; physical overspeed, launch, spin, and impossible
    -- displacement remain independently guarded below.
    local elapsed = math.max(0, now - safety.StartedAt)
    local displacement = position - safety.StartPosition
    local horizontalDisplacement = Vector3.new(
        displacement.X,
        0,
        displacement.Z
    ).Magnitude
    local maximumDisplacement = (safety.ExpectedTravel or 0)
        * self.FlingDisplacementFactor + self.FlingDisplacementMargin
    if elapsed >= 0.03 and horizontalDisplacement > maximumDisplacement then
        return "displacement overshoot"
    end
    return nil
end

function State:BrakeFling(safety, root, reason, now)
    local mover = safety and safety.Mover
    if mover and mover.Parent == root then
        pcall(mover.Destroy, mover)
    end
    if root and root.Parent then
        pcall(function()
            root.AssemblyLinearVelocity = ZERO
            root.AssemblyAngularVelocity = ZERO
        end)
    end
    for _, telemetry in ipairs(State.DashTelemetry) do
        if telemetry.Root == root
            and math.abs(telemetry.RequestedAt - safety.StartedAt) <= 0.05 then
            telemetry.Rejected = true
        end
    end
    self.DashSafety = nil
    self.FlingBrakeUntil = now + self.FlingBrakeDuration
    self.FlingGuardTrips += 1
    self.LastFlingGuardReason = reason
    self.LastBlockReason = "Fling brake: " .. reason
    pushReplay("fling_brake", now, {
        Reason = reason,
        Horizontal = State.MaximumObservedDashHorizontalSpeed,
        Vertical = State.MaximumObservedDashVerticalSpeed,
        Angular = State.MaximumObservedDashAngularSpeed,
    })
end

function State:MonitorDashSafety(now, character, root)
    if now < self.FlingBrakeUntil then
        if root and root.Parent then
            pcall(function()
                root.AssemblyLinearVelocity = ZERO
                root.AssemblyAngularVelocity = ZERO
            end)
        end
        return
    end
    local safety = self.DashSafety
    if not safety then
        return
    end
    if not root or root ~= safety.Root or character ~= safety.Character
        or not root.Parent then
        self.DashSafety = nil
        return
    end
    if now > safety.EndsAt then
        self.DashSafety = nil
        return
    end
    if not safety.Mover or not safety.Mover.Parent then
        safety.Mover = self:FindNewDashVelocityMover(
            root,
            safety.PreexistingMovers
        )
    end
    local velocity = root.AssemblyLinearVelocity
    local angularVelocity = root.AssemblyAngularVelocity
    local horizontalSpeed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
    self.MaximumObservedDashHorizontalSpeed = math.max(
        self.MaximumObservedDashHorizontalSpeed,
        horizontalSpeed
    )
    self.MaximumObservedDashVerticalSpeed = math.max(
        self.MaximumObservedDashVerticalSpeed,
        math.abs(velocity.Y)
    )
    self.MaximumObservedDashAngularSpeed = math.max(
        self.MaximumObservedDashAngularSpeed,
        angularVelocity.Magnitude
    )
    local reason = self:DashFlingReason(
        safety,
        velocity,
        angularVelocity,
        root.Position,
        now
    )
    if reason then
        self:BrakeFling(safety, root, reason, now)
    end
end

local function nativeDodge(threat, suppliedPlan)
    if State.SuppressActions or not State.Enabled
        or State.Initializing or State.AttemptPending then
        State.LastBlockReason = State.AttemptPending
            and "Awaiting dash acknowledgement" or "Inactive"
        return false
    end
    if threat.Profile and threat.Profile.Learned
        and (threat.Confidence or 0) < 0.82
        and not threat.PhysicalProjectile
        and not threat.Emergency then
        return false
    end
    if (threat.RequestCount or 0) >= 2 then
        State.LastBlockReason = "Threat attempt limit"
        return false
    end
    if (threat.WireRequestCount or 0) >= 2 then
        State.LastBlockReason = "Threat wire limit"
        return false
    end
    local character, humanoid, localRoot = getLocalCharacter()
    if not nativeDashAvailable(character, humanoid) then
        State.LastBlockReason = "Native dash unavailable"
        return false
    end

    local phantomStep = State:IsPhantomStepActive(character)
    local now = os.clock()
    if now < State.FlingBrakeUntil then
        State.LastBlockReason = "Fling brake settling"
        return false
    end
    local previousSafety = State.DashSafety
    if phantomStep and previousSafety
        and now <= previousSafety.EndsAt then
        State.LastBlockReason = "Phantom dash settling"
        return false
    elseif previousSafety and now > previousSafety.EndsAt then
        State.DashSafety = nil
    end
    if phantomStep and humanoid.FloorMaterial == Enum.Material.Air then
        State.LastBlockReason = "Phantom ground safety"
        return false
    end
    if phantomStep then
        local rootVelocity = localRoot.AssemblyLinearVelocity
        local rootAngular = localRoot.AssemblyAngularVelocity
        if math.abs(rootVelocity.Y) > 35 or rootAngular.Magnitude > 18 then
            State.LastBlockReason = "Unstable movement state"
            return false
        end
    end
    local freshnessLimit = math.max(0.025, 2 * State.FrameMean)
    if not threat.LastEvaluatedAt
        or now - threat.LastEvaluatedAt > freshnessLimit
        or threat.ContactIn == nil then
        State.LastBlockReason = "Threat changed before act"
        State.StaleThreatDrops += 1
        return false
    end
    if threat.TerrainBlockedUntil and now < threat.TerrainBlockedUntil then
        State.LastBlockReason = "Terrain route retry"
        return false
    end
    local function rejectTerrain(reason)
        State.TerrainRejectedDodges += 1
        State.LastTerrainStatus = reason or "No safe ground"
        State.LastBlockReason = State.LastTerrainStatus
        State.DodgePlan = nil
        threat.TerrainBlockedUntil = now + math.min(
            0.025,
            math.max(State.FrameMean, 1 / 120)
        )
        pushReplay("dodge_ground_rejected", now, {
            Threat = threat.Profile and threat.Profile.Name or "Unknown",
            Reason = State.LastTerrainStatus,
        })
        updateStatus(true)
        return false
    end
    local minimumRequestInterval = math.max(MIN_REQUEST_INTERVAL, State.FrameMean)
    if phantomStep then
        -- Phantom destroys its current velocity driver after 0.05 seconds.
        -- A second charge must not be sent while that driver still exists.
        minimumRequestInterval = math.max(
            minimumRequestInterval,
            State.PhantomSettleInterval
        )
    end
    if now - State.LastRequestAt < minimumRequestInterval then
        State.LastBlockReason = "Native request spacing"
        return false
    end
    local info = resolveDashInfo(character)
    if not info then
        State.LastBlockReason = "Dash controller unavailable"
        return false
    end
    local plan = suppliedPlan
    if not plan or plan.Threat ~= threat
        or plan.Generation ~= State.Generation then
        plan = chooseDodgePlan(threat, now, character, humanoid, localRoot)
    end
    local camera = workspace.CurrentCamera
    local cameraLook = camera and horizontalUnit(camera.CFrame.LookVector)
        or horizontalUnit(localRoot.CFrame.LookVector)
    if plan and (
        plan.CameraLook and plan.CameraLook:Dot(cameraLook) < math.cos(math.rad(10))
        or plan.PlannedRootPosition
            and (plan.PlannedRootPosition - localRoot.Position).Magnitude > 2.5
    ) then
        -- Cardinal codes are camera-relative. Never execute a delayed plan in
        -- a different world direction than the one whose collisions/ground
        -- were solved.
        plan = chooseDodgePlan(
            threat,
            now,
            character,
            humanoid,
            localRoot,
            threat.Emergency
        )
    end
    if phantomStep and State.StrictPhantomGroundSafety
        and (not plan or plan.TerrainSafe ~= true) then
        return rejectTerrain(
            plan and plan.TerrainReason or "No supported Phantom route"
        )
    end
    local directionName = plan and plan.Name
    local direction = plan and plan.Direction
    if not direction then
        directionName, direction = chooseDodgeDirection(
            threat,
            now,
            character,
            humanoid,
            localRoot
        )
    end
    if plan and plan.ControllerDirection then
        directionName = plan.ControllerDirection
        direction = State:ControllerDirectionVector(
            directionName,
            cameraLook
        )
    else
        directionName, direction = State:ExecutableDashDirection(
            cameraLook,
            direction
        )
    end

    local requireGround = phantomStep
        or humanoid.FloorMaterial ~= Enum.Material.Air
    if requireGround then
        local parameters = State:BuildTerrainParameters(character)
        local path = State:TerrainPathVector(
            character,
            { Velocity = localRoot.AssemblyLinearVelocity },
            direction
        )
        local limitedPath, obstacle = State:LimitTerrainPath(
            localRoot.Position,
            path,
            parameters
        )
        local groundSafe, groundReason, groundSupports
        if phantomStep and obstacle then
            groundSafe = false
            groundReason = State:IsBarrierGeometry(obstacle)
                and "Barrier obstructs Phantom path"
                or "Obstacle obstructs Phantom path"
            groundSupports = 0
        else
            groundSafe, groundReason, groundSupports =
                State:GroundPathSafe(
                    localRoot.Position,
                    limitedPath,
                    parameters,
                    phantomStep
                )
        end
        if not groundSafe then
            return rejectTerrain(groundReason)
        end
        State.LastTerrainStatus = string.format(
            "Supported (%d rails)",
            groundSupports or 0
        )
    end
    local requestBudgetToken = reserveRequestSlot(now)
    if not requestBudgetToken then
        return false
    end
    local reactionStartedAt = threat.FirstConfirmedAt
    local requestAt = os.clock()
    local originalMovement = humanoid.MoveDirection
    local previousControllerPressed = rawget(shared, "controllerpressed")
    local beforeRecentDash = character:GetAttribute("RecentDash")
    local preexistingVelocityMovers = setmetatable({}, { __mode = "k" })
    if phantomStep then
        for _, child in ipairs(localRoot:GetChildren()) do
            if State:IsDashVelocityMover(child) then
                preexistingVelocityMovers[child] = true
            end
        end
    end
    restoreDirectionLease(nil, false)
    State.DirectionLeaseToken += 1
    local leaseToken = State.DirectionLeaseToken
    local lease = {
        Token = leaseToken,
        Generation = State.Generation,
        Character = character,
        Humanoid = humanoid,
        ForcedDirection = direction,
        OriginalMoveDirection = originalMovement,
        PreviousControllerPressed = previousControllerPressed,
        ChangedController = previousControllerPressed ~= true,
        BeganAt = requestAt,
        ReleaseDeadline = requestAt + math.clamp(
            5 * State.FrameMean,
            0.08,
            0.2
        ),
    }
    State.DirectionLease = lease
    State.DirectionLeaseStarts += 1
    State.LastRequestAt = requestAt
    State.DodgeAttempts += 1
    State.AttemptPending = {
        Character = character,
        Threat = threat,
        DirectionName = directionName,
        Direction = direction,
        StartPosition = localRoot.Position,
        BaselineVelocity = localRoot.AssemblyLinearVelocity,
        LeaseToken = leaseToken,
        BeforeRecentDash = beforeRecentDash,
        WasPhantomStep = phantomStep,
        BeforePhantomStacks = phantomStep
            and State:GetPhantomStackCount(character, requestAt) or nil,
        RequestBudgetToken = requestBudgetToken,
        RequestedAt = requestAt,
        ExpiresAt = requestAt + math.clamp(
            State.DashStartupMean
                + 2 * State.DecayingWorstFrame
                + State.PingMean
                + State.PingDeviation,
            DASH_ACK_TIMEOUT,
            MAX_DASH_ACK_LOCK
        ),
    }
    State.AttemptPending.Telemetry = State:BeginDashTelemetry(
        character,
        localRoot,
        direction,
        requestAt,
        localRoot.AssemblyLinearVelocity,
        phantomStep
    )
    State.DodgePlan = nil
    pushReplay("dodge_request", requestAt, {
        Threat = threat.Profile.Name,
        Direction = directionName,
        Delay = plan and plan.Delay or 0,
        Confidence = plan and plan.Confidence or threat.Confidence or 0.75,
    })

    -- The controller's normal uncharged Q path enters its release routine
    -- directly. Firing only DashingReleased avoids the hold/charge state and
    -- therefore adds no artificial delay.
    local releaseAt
    local ok, message = xpcall(function()
        rawset(shared, "controllerpressed", true)
        humanoid:Move(direction, false)
        releaseAt = os.clock()
        info:Fire({ DashingReleased = true })
        State.DashReleases += 1
        if phantomStep then
            State.PhantomDashReleases += 1
            State:GetPhantomCharges(character, os.clock())
        end
    end, debug.traceback)
    if not ok then
        if State.AttemptPending and State.AttemptPending.Telemetry then
            State.AttemptPending.Telemetry.Rejected = true
        end
        restoreDirectionLease(leaseToken, false)
        releaseRequestSlot(requestBudgetToken)
        State.AttemptPending = nil
        State.DodgePlan = nil
        State.RejectedDodges += 1
        reportError("native dodge", message)
        return false
    end
    -- A successful Info:Fire consumed a real native request even if its
    -- acknowledgement is later lost.  Keep that request in the global budget
    -- and separately cap wire sends so an ACK edge case cannot stack dashes.
    if State.AttemptPending then
        State.AttemptPending.RequestBudgetToken = nil
    end
    threat.WireRequestCount = (threat.WireRequestCount or 0) + 1
    releaseAt = releaseAt or os.clock()
    State.LastRequestAt = releaseAt
    if phantomStep then
        local expectedTravel = getDashDistance(character, 0.5)
        local expectedPeakSpeed = getDashDistance(
            character,
            State.PhantomStepDuration
        ) / math.max(State.PhantomStepDuration, 0.001)
        State.DashSafety = {
            Character = character,
            Root = localRoot,
            Direction = direction,
            StartedAt = releaseAt,
            EndsAt = releaseAt + State.FlingGuardWindow,
            StartPosition = localRoot.Position,
            ExpectedPeakSpeed = expectedPeakSpeed,
            ExpectedTravel = expectedTravel,
            PreexistingMovers = preexistingVelocityMovers,
            Mover = State:FindNewDashVelocityMover(
                localRoot,
                preexistingVelocityMovers
            ),
        }
    end
    local reactionMilliseconds = reactionStartedAt and math.max(
        0,
        (releaseAt - reactionStartedAt) * 1000
    ) or -1
    if State.AttemptPending then
        State.AttemptPending.RequestedAt = releaseAt
        State.AttemptPending.ReleaseAt = releaseAt
        State.AttemptPending.ReactionMilliseconds = reactionMilliseconds
        State.AttemptPending.AcknowledgementMilliseconds = -1
        State.AttemptPending.ExpiresAt = releaseAt + math.clamp(
            State.DashStartupMean
                + 2 * State.DecayingWorstFrame
                + State.PingMean
                + State.PingDeviation,
            DASH_ACK_TIMEOUT,
            MAX_DASH_ACK_LOCK
        )
    end
    pushReplay("dodge_release", releaseAt, {
        Threat = threat.Profile.Name,
        Reaction = reactionMilliseconds,
        PhantomStep = phantomStep,
    })
    State.LastBlockReason = "None"
    confirmDodgeAttempt(os.clock())
    return true
end

local function insertTopThreat(threat)
    local top = State.TopThreats
    local insertAt = #top + 1
    for index = 1, #top do
        if threat.Deadline < top[index].Deadline then
            insertAt = index
            break
        end
    end
    if insertAt > MAX_DIRECTION_THREATS then
        return
    end
    local finalIndex = math.min(#top + 1, MAX_DIRECTION_THREATS)
    for index = finalIndex, insertAt + 1, -1 do
        top[index] = top[index - 1]
    end
    top[insertAt] = threat
end

local function refreshWatcher(watcher)
    local character = watcher.Character
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local root = character:FindFirstChild("HumanoidRootPart")
    if watcher.Root ~= root then
        watcher.Root = root
        watcher.Motion = nil
    end
    watcher.Humanoid = humanoid

    local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
    if animator == watcher.Animator and watcher.AnimationConnection
        and watcher.AnimationConnection.Connected then
        return
    end
    disconnect(watcher.AnimationConnection)
    watcher.AnimationConnection = nil
    watcher.Animator = animator
    if animator then
        local generation = watcher.Generation
        watcher.AnimationConnection = animator.AnimationPlayed:Connect(guarded(
            "animation",
            function(track)
                if State.Enabled and State.Generation == generation then
                    watcher.QueueAttack(character, track, generation)
                end
            end
        ))
        -- Catch an attack that was already playing when F1 was enabled or an
        -- Animator was replaced. The bound keeps respawn/setup work finite.
        local ok, tracks = pcall(
            animator.GetPlayingAnimationTracks,
            animator
        )
        if ok then
            for index = 1, math.min(#tracks, 24) do
                watcher.QueueAttack(character, tracks[index], generation)
            end
        end
    end
end

local queueAttack

local function watchCharacter(character, generation)
    if not State.Enabled or generation ~= State.Generation
        or character == LocalPlayer.Character
        or not character:IsA("Model")
        or State.Watchers[character]
        or State.WatcherCount >= MAX_WATCHERS then
        return
    end

    local watcher = {
        Character = character,
        Generation = generation,
        QueueAttack = function(targetCharacter, track, callbackGeneration)
            queueAttack(targetCharacter, track, callbackGeneration)
        end,
        NextSampleAt = 0,
        WeaponParts = setmetatable({}, { __mode = "k" }),
        WeaponSamples = setmetatable({}, { __mode = "k" }),
    }
    State.Watchers[character] = watcher
    State.WatcherCount += 1
    rebuildWeaponCache(watcher)
    refreshWatcher(watcher)
    watcher.DescendantAddedConnection = character.DescendantAdded:Connect(guarded(
        "character descendant added",
        function(object)
            if not State.Enabled or State.Generation ~= generation then
                return
            end
            if object:IsA("BasePart") then
                cacheWeaponPart(watcher, object)
            end
            if object:IsA("Animator")
                    or object:IsA("Humanoid")
                    or object.Name == "HumanoidRootPart" then
                refreshWatcher(watcher)
            end
        end
    ))
    watcher.DescendantRemovingConnection = character.DescendantRemoving:Connect(
        guarded("character descendant removing", function(object)
            if State.Generation ~= generation then
                return
            end
            if object == watcher.Animator then
                disconnect(watcher.AnimationConnection)
                watcher.AnimationConnection = nil
                watcher.Animator = nil
            end
            if object == watcher.Root or object == watcher.Humanoid then
                watcher.Motion = nil
                watcher.Root = nil
                watcher.Humanoid = nil
            end
            if watcher.WeaponParts then
                watcher.WeaponParts[object] = nil
            end
            if watcher.WeaponSamples then
                watcher.WeaponSamples[object] = nil
            end
        end)
    )
end

local function disconnectWatcher(character)
    local watcher = State.Watchers[character]
    if not watcher then
        return
    end
    disconnect(watcher.AnimationConnection)
    disconnect(watcher.DescendantAddedConnection)
    disconnect(watcher.DescendantRemovingConnection)
    State.Watchers[character] = nil
    State.RecentEnemyDashes[character] = nil
    State.WatcherCount = math.max(0, State.WatcherCount - 1)
    for index = #State.Pending, 1, -1 do
        local threat = State.Pending[index]
        if threat.Character == character then
            local persistentFlight = threat.Profile.Kind == "Ranged"
                and threat.RangedReleased
                and threat.Profile.ProjectileSpeed ~= math.huge
                and threat.RangedState == "Flight"
                and threat.RangedFlightEndAt
                and threat.RangedFlightEndAt > os.clock()
            if persistentFlight then
                threat.DetachedShooter = true
            else
                removeThreatAt(index)
            end
        end
    end
end

local function sampleCharacters(now, localRoot)
    local localPosition = localRoot.Position
    for _, watcher in pairs(State.Watchers) do
        if not watcher.Root or not watcher.Humanoid or not watcher.Animator then
            refreshWatcher(watcher)
        end
        local root = watcher.Root
        if root and root.Parent == watcher.Character then
            local distance = (root.Position - localPosition).Magnitude
            if distance <= NEAR_SAMPLE_RANGE or now >= watcher.NextSampleAt then
                watcher.Motion = sampleMotion(watcher.Motion, root, now)
                watcher.NextSampleAt = distance <= NEAR_SAMPLE_RANGE
                    and now
                    or now + FAR_SAMPLE_INTERVAL
            end
        end
    end
end

local function processFrame(deltaTime, generation)
    if not State.Enabled or generation ~= State.Generation then
        return
    end
    local now = os.clock()
    local predictionStarted = now
    State.FrameDeadline = predictionStarted + math.clamp(
        (deltaTime or State.FrameMean) * 0.18,
        0.0018,
        0.0032
    )
    local lease = State.DirectionLease
    if lease and now >= lease.ReleaseDeadline then
        restoreDirectionLease(lease.Token, false)
    end
    updateTiming(deltaTime, now)
    local localCharacter, localHumanoid, localRoot = getLocalCharacter()
    State:MonitorDashSafety(now, localCharacter, localRoot)
    if localCharacter and localRoot then
        State.LocalMotion = sampleMotion(State.LocalMotion, localRoot, now)
        sampleCharacters(now, localRoot)
    else
        State.LocalMotion = nil
    end
    sampleProjectiles(now, State.LocalMotion)
    State:SampleDashTelemetry(now)
    confirmDodgeAttempt(now)

    local evaluationOrder = State.EvaluationOrder
    table.clear(evaluationOrder)
    for _, threat in ipairs(State.Pending) do
        evaluationOrder[#evaluationOrder + 1] = threat
    end
    table.sort(evaluationOrder, function(first, second)
        local firstPriority = first.Emergency and -math.huge
            or first.ContactIn and (first.Deadline or math.huge)
            or first.PreliminaryDeadline or math.huge
        local secondPriority = second.Emergency and -math.huge
            or second.ContactIn and (second.Deadline or math.huge)
            or second.PreliminaryDeadline or math.huge
        return firstPriority < secondPriority
    end)

    local evaluatedThreats = 0
    for orderIndex, threat in ipairs(evaluationOrder) do
        local currentIndex = State.PendingIndex[threat.Key]
        if currentIndex then
            if now > threat.ExpiresAt then
                removeThreatAt(currentIndex)
            else
                local absoluteUrgency = threat.ContactIn
                    and (threat.Deadline or now)
                    or threat.PreliminaryDeadline or now
                local ambientThreat = orderIndex > 1
                    and not threat.ContactIn
                    and absoluteUrgency - now > MPC_ARM_WINDOW
                    and not threat.PhysicalProjectile
                    and not threat.WeaponSample
                if ambientThreat and not threat.NextMaintenanceAt then
                    threat.NextMaintenanceAt = now + 0.04
                        + (orderIndex % 4) * 0.01
                end
                local safelyDeferrable = ambientThreat
                    and now < (threat.NextMaintenanceAt or now)
                if os.clock() >= State.FrameDeadline and safelyDeferrable then
                    threat.DeferredFrames = (threat.DeferredFrames or 0) + 1
                    State.DeferredThreatEvaluations += 1
                else
                    threat.DeferredFrames = 0
                    if ambientThreat then
                        threat.NextMaintenanceAt = now + 0.05
                            + (orderIndex % 4) * 0.01
                    else
                        threat.NextMaintenanceAt = nil
                    end
                    local ok, valid, reason = xpcall(
                        evaluateThreat,
                        debug.traceback,
                        threat,
                        now,
                        localCharacter,
                        localRoot,
                        State.LocalMotion
                    )
                    evaluatedThreats += 1
                    if not ok then
                        threat.ErrorCount = (threat.ErrorCount or 0) + 1
                        State.ErrorCount += 1
                        if threat.ErrorCount <= 2 then
                            warn("[Ink Auto Dodge] quarantined threat: " .. tostring(valid))
                        end
                        if threat.ErrorCount >= 2 then
                            currentIndex = State.PendingIndex[threat.Key]
                            if currentIndex then
                                removeThreatAt(currentIndex)
                            end
                        end
                    elseif not valid
                        and (reason == "terminal" or reason == "finished") then
                        currentIndex = State.PendingIndex[threat.Key]
                        if currentIndex then
                            removeThreatAt(currentIndex)
                        end
                    else
                        threat.ErrorCount = 0
                    end
                end
            end
        end
    end
    State.LastEvaluatedThreats = evaluatedThreats

    table.clear(State.TopThreats)
    table.clear(State.EvaluationOrder)
    local decisionNow = os.clock()
    local freshnessLimit = math.max(0.025, 2 * State.FrameMean)
    for _, threat in ipairs(State.Pending) do
        if threat.ContactIn and threat.LastEvaluatedAt
            and decisionNow - threat.LastEvaluatedAt <= freshnessLimit then
            insertTopThreat(threat)
        elseif threat.ContactIn then
            State.StaleThreatDrops += 1
        end
    end
    local mostUrgent = State.TopThreats[1]
    local plan = State.DodgePlan
    if plan and (
        plan.Generation ~= State.Generation
        or not plan.Threat
        or not State.PendingIndex[plan.Threat.Key]
        or plan.Threat ~= mostUrgent
    ) then
        State.DodgePlan = nil
        plan = nil
    end
    if mostUrgent and localCharacter and localHumanoid and localRoot then
        if State.AttemptPending then
            State.LastBlockReason = "Awaiting dash acknowledgement"
        elseif not nativeDashAvailable(localCharacter, localHumanoid) then
            -- Keep collision prediction current, but do not burn the MPC and
            -- terrain budget on an action the native controller cannot take.
            State.LastBlockReason = "Native dash unavailable"
            State.DodgePlan = nil
            plan = nil
        elseif mostUrgent.Emergency then
            if not plan then
                State.DodgePlan = chooseDodgePlan(
                    mostUrgent,
                    decisionNow,
                    localCharacter,
                    localHumanoid,
                    localRoot,
                    true
                )
                plan = State.DodgePlan
            end
            nativeDodge(mostUrgent, plan)
        elseif mostUrgent.Deadline - decisionNow <= MPC_ARM_WINDOW then
            local timeToDeadline = mostUrgent.Deadline - decisionNow
            local replanInterval = timeToDeadline <= 0.12
                and math.max(State.FrameMean, 1 / 120)
                or MPC_REPLAN_INTERVAL
            if not plan or decisionNow >= State.NextMpcAt then
                State.NextMpcAt = decisionNow + replanInterval
                local newPlan = localHumanoid and chooseDodgePlan(
                    mostUrgent,
                    decisionNow,
                    localCharacter,
                    localHumanoid,
                    localRoot
                ) or nil
                if newPlan then
                    local committed = plan
                        and plan.RequestAt - decisionNow <= MPC_COMMIT_WINDOW
                    if committed and newPlan.RequestAt > plan.RequestAt then
                        -- Keep the already evaluated control intact. Mixing a
                        -- new direction with the old activation frame would
                        -- execute a direction/time pair the solver never saw.
                        newPlan = plan
                    end
                    State.DodgePlan = newPlan
                    plan = newPlan
                end
            end
            local actNow = os.clock()
            if plan and (
                plan.RequestAt <= actNow + 0.5 * State.FrameMean
                or mostUrgent.Deadline <= actNow
            ) then
                nativeDodge(mostUrgent, plan)
            end
        else
            State.DodgePlan = nil
        end
    elseif not mostUrgent then
        State.DodgePlan = nil
        State.LastBlockReason = "None"
    end
    local work = os.clock() - predictionStarted
    State.LastFrameWork = work
    State.FrameWorkMean += (work - State.FrameWorkMean) * 0.08
    State.DecayingWorstWork = math.max(
        work,
        State.DecayingWorstWork * math.exp(-1.5 * math.max(deltaTime, 0.001))
    )
    updateStatus(false)
    State.ConsecutiveErrors = 0
end

local function evaluateImmediately(threat, now, allowDodge)
    if allowDodge and State.AttemptPending then
        return
    end
    local localCharacter, _, localRoot = getLocalCharacter()
    if not localCharacter or not localRoot then
        return
    end
    State.LocalMotion = sampleMotion(State.LocalMotion, localRoot, now)
    local watcher = State.Watchers[threat.Character]
    if watcher then
        refreshWatcher(watcher)
        if watcher.Root then
            watcher.Motion = sampleMotion(watcher.Motion, watcher.Root, now)
        end
    end
    local valid = evaluateThreat(
        threat,
        now,
        localCharacter,
        localRoot,
        State.LocalMotion
    )
    local actNow = os.clock()
    if allowDodge and valid and threat.ContactIn
        and (threat.Emergency or threat.Deadline <= actNow) then
        nativeDodge(threat)
    end
end

local function dodgeMostUrgentNow(now)
    if State.AttemptPending then
        return
    end
    local mostUrgent
    now = os.clock()
    local freshnessLimit = math.max(0.025, 2 * State.FrameMean)
    for _, threat in ipairs(State.Pending) do
        if threat.ContactIn and threat.LastEvaluatedAt
            and now - threat.LastEvaluatedAt <= freshnessLimit and (
            not mostUrgent or threat.Deadline < mostUrgent.Deadline
        ) then
            mostUrgent = threat
        end
    end
    if mostUrgent
        and (mostUrgent.Emergency or mostUrgent.Deadline <= now) then
        nativeDodge(mostUrgent)
    end
end

local function promoteDashAttacks(attackerCharacter, now)
    State.RecentEnemyDashes[attackerCharacter] = now + DASH_LINK_WINDOW
    for _, threat in ipairs(State.Pending) do
        if threat.Character == attackerCharacter then
            -- The animation says a dash happened, not where it went.  The
            -- next motion sample must confirm approach before it becomes an
            -- incoming dash attack.
            threat.DashHintUntil = now + DASH_LINK_WINDOW
            threat.ExpiresAt = math.max(threat.ExpiresAt, now + 0.9)
            evaluateImmediately(threat, now, false)
        end
    end
    dodgeMostUrgentNow(now)
end

queueAttack = function(attackerCharacter, track, generation)
    if not State.Enabled or generation ~= State.Generation then
        return
    end
    local now = os.clock()
    local lastSeenAt = State.SeenTracks[track]
    if lastSeenAt and now - lastSeenAt < 0.05 then
        return
    end
    State.SeenTracks[track] = now

    local animation = track.Animation
    local id = animation and normalizeAnimationId(animation.AnimationId)
    if id and State.DashIds and State.DashIds[id] then
        promoteDashAttacks(attackerCharacter, now)
        return
    end

    State.AttackEvents += 1
    local watcher = State.Watchers[attackerCharacter]
    local profile = id and State.Profiles and State.Profiles[id]
    local learnedConfidence
    if not profile and id and animation and watcher then
        profile, learnedConfidence = observeDynamicAnimation(
            animation,
            id,
            watcher,
            now
        )
    end
    if not profile or hasGunToken(profile.Name) or hasGunToken(profile.Weapon) then
        return
    end
    State.RecognizedAttacks += 1

    local localCharacter, _, localRoot = getLocalCharacter()
    if not watcher or not localCharacter or not localRoot then
        return
    end
    refreshWatcher(watcher)
    if not watcher.Root then
        return
    end
    State.LocalMotion = sampleMotion(State.LocalMotion, localRoot, now)
    watcher.Motion = sampleMotion(watcher.Motion, watcher.Root, now)

    local speed = math.max(math.abs(track.Speed), 0.05)
    local timePosition = math.max(track.TimePosition, 0)
    local perAnimationCalibration = calibrationFor(profile, id)
    robustUpdate(
        perAnimationCalibration.Callback,
        math.clamp(timePosition / speed, 0, 0.35),
        0,
        0.35,
        0.08
    )
    local frameQuantum = math.max(State.FrameMean, 1 / 240)
    robustUpdate(
        perAnimationCalibration.ReplicationPhase,
        (timePosition / speed) % frameQuantum,
        0,
        0.05,
        0.02
    )
    local effectiveStart, effectiveEnd, effectiveRelease = effectiveTiming(
        profile,
        id
    )
    local relativePosition = State.LocalMotion.Position - watcher.Motion.Position
    local targetDirection = horizontalUnit(
        relativePosition,
        horizontalUnit(watcher.Root.CFrame.LookVector)
    )
    local attackerVelocity = predictionVelocity(watcher.Motion, true)
    local attackerApproachSpeed = attackerVelocity:Dot(targetDirection)
    local attackerApproachAcceleration = watcher.Motion.Acceleration:Dot(
        targetDirection
    )
    local attackerAlignment = attackerVelocity.Magnitude > 1
        and horizontalUnit(attackerVelocity, targetDirection):Dot(targetDirection)
        or 0
    local distance = relativePosition.Magnitude
    local relativeVelocity = State.LocalMotion.Velocity - watcher.Motion.Velocity
    local closing = distance > 0.01
        and -relativePosition.Unit:Dot(relativeVelocity)
        or 0
    local recentDash = State.RecentEnemyDashes[attackerCharacter]
    local dashHint = recentDash and recentDash >= now
    local baseReach = math.max(
        profile.Range or 0,
        profile.FarReach or 0,
        profile.Radius or 0
    )
    local dashAligned = attackerApproachSpeed >= DASH_CONFIRM_MIN_SPEED
        and attackerAlignment >= DASH_CONFIRM_DOT
    local dashAttack = dashHint
            and (dashAligned or distance <= baseReach + BODY_RADIUS + 2)
        or attackerApproachSpeed >= DASH_CLOSING_SPEED
            and attackerAlignment >= DASH_CONFIRM_DOT
        or attackerApproachAcceleration >= DASH_CLOSING_ACCELERATION
            and dashAligned
    local activeHorizon = math.clamp(
        (effectiveEnd - timePosition) / speed,
        0,
        MAX_PREDICTION_TIME
    )
    local approachSpeed = math.clamp(math.max(
        closing,
        attackerApproachSpeed,
        profile.MobilitySpeed or 0,
        dashAttack and 140 or 0,
        0
    ), 0, 220)
    local approachAcceleration = math.clamp(
        math.max(attackerApproachAcceleration, 0),
        0,
        dashAttack and 320 or 110
    )
    local acquisitionRange = profile.Kind == "Ranged"
        and profile.Range
        or math.min(
            NEAR_SAMPLE_RANGE,
            baseReach + BODY_RADIUS + QUEUE_MARGIN
                + approachSpeed * activeHorizon
                + 0.5 * approachAcceleration
                    * activeHorizon * activeHorizon
        )
    if distance > acquisitionRange then
        return
    end

    local untilActive = math.max(
        0,
        ((profile.Kind == "Ranged" and effectiveRelease or effectiveStart)
            - timePosition) / speed
    )
    local lead = getPredictionLead(profile, id)
    local lifetime
    if profile.Kind == "Ranged" then
        lifetime = untilActive + 1.5
        if profile.ProjectileSpeed ~= math.huge
            and profile.ProjectileSpeed > 0 then
            lifetime = untilActive
                + profile.Range / profile.ProjectileSpeed
                + 1.5
        end
        lifetime = math.min(lifetime, 5)
    else
        lifetime = math.clamp(
            (effectiveEnd - timePosition) / speed + 0.65,
            0.8,
            4
        )
    end
    local aimDirection = unitOrFallback(watcher.Root.CFrame.LookVector)
    local launchSource
    local launchSourceUsesDirection = false
    local launchOrigin = watcher.Motion.Position
    if profile.Kind == "Ranged" then
        launchSource, launchSourceUsesDirection = findLaunchSource(
            attackerCharacter,
            profile,
            watcher
        )
        launchOrigin, aimDirection = readLaunchSource(
            launchSource,
            launchSourceUsesDirection,
            launchOrigin,
            aimDirection
        )
    end
    local threat = {
        Key = {},
        Track = track,
        AnimationId = id,
        Character = attackerCharacter,
        Profile = profile,
        TimingKey = id,
        Confidence = learnedConfidence or (profile.Exact and 1 or 0.76),
        Provenance = profile.Learned and "LearnedBehavior"
            or profile.Exact and "Exact"
            or "AllowlistedFolder",
        DashAttack = dashAttack and true or false,
        DashHintUntil = dashHint and recentDash or nil,
        DashConfirmedUntil = dashAttack and now + DASH_CONFIRM_HOLD or nil,
        CreatedAt = now,
        ExpiresAt = now + lifetime,
        PlaybackSpeed = speed,
        LogicalElapsed = timePosition,
        LastPhaseAt = now,
        PreviousRelative = relativePosition,
        PreviousRelativeAt = now,
        LookDirection = horizontalUnit(aimDirection),
        AimDirection = aimDirection,
        LaunchSource = launchSource,
        LaunchSourceUsesDirection = launchSourceUsesDirection,
        LastRangedElapsed = profile.Kind == "Ranged" and timePosition or nil,
        LastRangedAt = profile.Kind == "Ranged" and now or nil,
        LastRangedAttackerPosition = profile.Kind == "Ranged"
            and launchOrigin or nil,
        LastRangedAimDirection = profile.Kind == "Ranged"
            and aimDirection or nil,
        LastRangedLocalPosition = profile.Kind == "Ranged"
            and State.LocalMotion.Position or nil,
        InitialDistance = distance,
        PreliminaryDeadline = now + untilActive - lead
            + math.max(0, distance - profile.Range)
                / math.max(approachSpeed, 30),
    }
    if not addThreat(threat) then
        return
    end
    pushReplay("attack_seen", now, {
        Id = id or "",
        Threat = profile.Name,
        Confidence = threat.Confidence,
        Distance = distance,
    })
    evaluateImmediately(threat, now, false)
    dodgeMostUrgentNow(now)
    updateStatus(false)
end

function State:RunSelfTest()
    local result = {}
    local sphere = sphereEntry(
        Vector3.new(10, 0, 0),
        Vector3.new(-10, 0, 0),
        1,
        0,
        2
    )
    result.SphereCCD = sphere ~= nil and math.abs(sphere - 0.9) < 0.001
    local capsule = movingPointCapsuleEntry(
        Vector3.new(8, 0, 0),
        Vector3.new(-16, 0, 0),
        2.5,
        1,
        0,
        1
    )
    result.CapsuleCCD = capsule ~= nil and capsule > 0 and capsule < 1
    local swept = sweptMovingSegmentCapsuleEntry(
        Vector3.new(8, -1, 0),
        Vector3.new(8, 1, 0),
        Vector3.new(-8, -1, 0),
        Vector3.new(-8, 1, 0),
        ZERO,
        ZERO,
        1,
        1
    )
    result.WeaponSweepCCD = swept ~= nil and swept >= 0 and swept <= 1
    local highSpeedFork = movingPointCapsuleEntry(
        Vector3.new(100, 0, 0),
        Vector3.new(-2000, 0, 0),
        BODY_HALF_HEIGHT,
        BODY_RADIUS + 0.35,
        0,
        0.1
    )
    result.HighSpeedForkCCD = highSpeedFork ~= nil
        and highSpeedFork > 0 and highSpeedFork < 0.1
    local broadMotion = {
        Position = ZERO,
        Velocity = ZERO,
    }
    local broadProjectile = {
        Center = Vector3.new(50, 0, 0),
        Velocity = Vector3.new(-1000, 0, 0),
        Acceleration = ZERO,
        Radius = 0.3,
        Model = "Linear",
        Signature = "fork",
        BounceCount = 0,
        StableSamples = 6,
        ModelConfidence = 0.95,
        HomingStrength = 0,
        TurnRate = 0,
    }
    result.IncomingProjectileBroadPhase = physicalBroadPhaseMayHit(
        broadProjectile,
        broadMotion,
        0.1,
        0.5
    ) == true
    broadProjectile.Center = Vector3.new(50, 0, 18)
    result.LateralProjectileBroadPhaseRejected = physicalBroadPhaseMayHit(
        broadProjectile,
        broadMotion,
        0.1,
        0.5
    ) == false
    result.GunExclusion = hasGunToken("Golden Revolver")
        and hasGunToken("RifleBullet")
        and not hasGunToken("Fork")
    local toward = Vector3.new(0, 0, 1)
    local away = -toward
    local farRelevant, farReason = analyticThreatRelevant(
        PROFILE_FAST_MELEE,
        40,
        toward,
        toward,
        0,
        0,
        0,
        0.35,
        0.75,
        false,
        0,
        false
    )
    result.StationaryFarMeleeRejected = not farRelevant
        and farReason == "out of reach"
    local sideRelevant, sideReason = analyticThreatRelevant(
        PROFILE_LUNGE,
        40,
        toward,
        Vector3.new(1, 0, 0),
        0,
        0,
        0,
        0.5,
        0.75,
        false,
        0,
        false
    )
    result.SideFacingMeleeRejected = not sideRelevant
        and sideReason == "not facing target"
    local closeRelevant = analyticThreatRelevant(
        PROFILE_FAST_MELEE,
        8,
        toward,
        toward,
        0,
        0,
        0,
        0.2,
        0.75,
        false,
        0,
        false
    )
    local awayDash = analyticThreatRelevant(
        PROFILE_LUNGE,
        40,
        toward,
        away,
        -120,
        -120,
        0,
        0.5,
        0.75,
        false,
        -1,
        false
    )
    result.CloseMeleeRetained = closeRelevant == true
    result.AwayDashRejected = awayDash == false
    result.BoundedAckLock = MAX_DASH_ACK_LOCK <= 0.28
    buildProfiles(false)
    result.ExactFork = State.Profiles
        and State.Profiles["85793691404836"]
        and State.Profiles["85793691404836"].Exact == true
    result.ExactThrow = State.Profiles
        and State.Profiles["72557176302052"]
        and State.Profiles["72557176302052"].ProjectileSignature == "fork"
    local probe = Instance.new("Folder")
    probe.Name = "Rock"
    local signature = projectileSignatureFor(probe)
    probe:Destroy()
    result.ProjectileAllowlist = signature == "rock"

    local historyProbe = {
        History = table.create(PROJECTILE_HISTORY_LIMIT),
        HistoryHead = 0,
        HistoryCount = 0,
    }
    local firstHistoryEntry
    for index = 1, PROJECTILE_HISTORY_LIMIT + 5 do
        pushProjectileHistory(
            historyProbe,
            index * 0.01,
            Vector3.new(index, 0, 0),
            Vector3.new(1, 0, 0)
        )
        if index == PROJECTILE_HISTORY_LIMIT then
            firstHistoryEntry = historyProbe.History[1]
        end
    end
    result.ProjectileHistoryCap = historyProbe.HistoryCount
            == PROJECTILE_HISTORY_LIMIT
        and #historyProbe.History == PROJECTILE_HISTORY_LIMIT
    result.ProjectileHistoryReuse = historyProbe.History[1]
        == firstHistoryEntry

    local modelProbe = {
        Base = Vector3.new(-0.5, 0, 0),
        Tip = Vector3.new(0.5, 0, 0),
        Center = ZERO,
        Radius = 0.25,
        Velocity = Vector3.new(10, 0, 0),
        Acceleration = Vector3.new(10, 0, 0),
        TangentialAcceleration = 10,
        TurnAxis = Vector3.new(0, 1, 0),
        TurnRate = 0,
        HomingStrength = 0,
        AngularVelocity = ZERO,
        PositionJitter = 0.1,
        ModelConfidence = 0.8,
        StableSamples = 6,
        SampleAt = os.clock(),
        Model = "Accelerating",
    }
    local acceleratedBase, acceleratedTip = physicalSegmentAt(modelProbe, 1)
    local acceleratedCenter = (acceleratedBase + acceleratedTip) * 0.5
    result.AcceleratingModel = math.abs(acceleratedCenter.X - 15) < 0.08

    modelProbe.Model = "Curved"
    modelProbe.Acceleration = ZERO
    modelProbe.TangentialAcceleration = 0
    modelProbe.TurnRate = math.pi / 2
    local curvedBase, curvedTip = physicalSegmentAt(modelProbe, 0.5)
    local curvedCenter = (curvedBase + curvedTip) * 0.5
    result.CurvedModel = math.abs(curvedCenter.Z) > 0.25

    modelProbe.Model = "Homing"
    modelProbe.TurnRate = 3
    modelProbe.HomingStrength = 0.8
    local homingBase, homingTip = physicalSegmentAt(
        modelProbe,
        0.5,
        Vector3.new(0, 0, 30)
    )
    local homingCenter = (homingBase + homingTip) * 0.5
    result.HomingModel = homingCenter.Z > 0.25
    result.UncertaintyGrowth = projectileUncertaintyAt(modelProbe, 0.5)
        >= projectileUncertaintyAt(modelProbe, 0)
        and projectileUncertaintyAt(modelProbe, MAX_PREDICTION_TIME) <= 7

    local incoming = Vector3.new(10, -2, 0)
    local normal = Vector3.new(1, 0, 0)
    local reflected = incoming - 2 * incoming:Dot(normal) * normal
    result.BounceReflection = reflected.X < 0
        and math.abs(reflected.Y - incoming.Y) < 0.001

    local hypothesisThreat = {
        AttackerMotion = {
            Position = ZERO,
            Velocity = Vector3.new(20, 0, 0),
            VelocityJitter = 2,
            PositionJitter = 0.1,
            ManeuverScore = 0.7,
            Intent = "Brake",
            IntentConfidence = 0.8,
            HeadingRate = 0,
            SpeedTrend = -100,
        },
        LookDirection = Vector3.new(1, 0, 0),
        TargetDirection = Vector3.new(0, 0, 1),
        DashAttack = true,
    }
    local leftOffset, leftPadding = reachableHypothesisAt(
        hypothesisThreat,
        0.4,
        2
    )
    local rightOffset, rightPadding = reachableHypothesisAt(
        hypothesisThreat,
        0.4,
        3
    )
    result.ReachableSetSymmetry = (leftOffset + rightOffset).Magnitude < 0.001
        and math.abs(leftPadding - rightPadding) < 0.001
        and leftPadding > 0
    local brakeOffset = reachableHypothesisAt(hypothesisThreat, 0.4, 4)
    local targetOffset = reachableHypothesisAt(hypothesisThreat, 0.4, 5)
    local totalIntentWeight = 0
    for hypothesisIndex = 1, MAX_PATH_HYPOTHESES do
        totalIntentWeight += State:IntentRawWeight(
            hypothesisThreat,
            hypothesisIndex
        )
    end
    result.IntentEnsemble = brakeOffset:Dot(
            hypothesisThreat.AttackerMotion.Velocity
        ) < 0
        and targetOffset.Z > 0
        and math.abs(totalIntentWeight - 1) < 0.001

    local obbMotion = {
        Position = ZERO,
        Velocity = ZERO,
        ShortVelocity = ZERO,
        Acceleration = ZERO,
        SampleAt = 0,
        LastChangedAt = 0,
    }
    local obbThreat = {
        DashAttack = false,
        WeaponSample = {
            CFrame = CFrame.new(),
            Size = Vector3.new(6, 1, 1),
            Radius = 0.2,
            CenterVelocity = ZERO,
            AngularVelocity = Vector3.new(0, math.pi, 0),
        },
    }
    local obbBase0, obbTip0 = weaponObbSegmentAt(
        obbThreat,
        0,
        obbMotion
    )
    local obbBase1, obbTip1 = weaponObbSegmentAt(
        obbThreat,
        0.1,
        obbMotion
    )
    result.RotatingObb = obbBase0 and obbBase1
        and unitOrFallback(obbTip0 - obbBase0):Dot(
            unitOrFallback(obbTip1 - obbBase1)
        ) < 0.999

    local timingProbe = copyLearnedProfile(PROFILE_THROW, {
        CalibrationKey = "SelfTestTiming",
    })
    local timingCalibration = calibrationFor(timingProbe, "SelfTestTiming")
    timingCalibration.StartEarly = { Mean = 0.03, Mad = 0.005, Samples = 3 }
    timingCalibration.EndLate = { Mean = 0.04, Mad = 0.005, Samples = 3 }
    timingCalibration.ReleaseEarly = { Mean = 0.02, Mad = 0.005, Samples = 3 }
    local safeStart, safeEnd, safeRelease = effectiveTiming(
        timingProbe,
        "SelfTestTiming"
    )
    result.ConservativeTiming = safeStart <= timingProbe.ActiveStart
        and safeEnd >= timingProbe.ActiveEnd
        and safeRelease <= timingProbe.ReleaseAt
    local impactProbe = {
        Profile = PROFILE_FAST_MELEE,
        TimingKey = "SelfTestImpact",
        ClosingSpeed = 100,
        AttackerApproachSpeed = 100,
        Uncertainty = 1,
    }
    local impactEarly, impactLate = State:ContactIntervalFor(impactProbe, 0.2)
    result.ImpactInterval = impactEarly and impactLate
        and impactEarly < 0.2 and impactLate > 0.2
    local tailProbe = newEstimator(0.01, 0.002)
    local tailBefore = State:ConservativeUpper(tailProbe)
    robustUpdate(tailProbe, 0.08, 0, 0.12, 0.08)
    result.TailEstimator = State:ConservativeUpper(tailProbe) > tailBefore
        and State:ConservativeUpper(tailProbe) >= tailProbe.Mean
    State.DashCurveCalibration.SelfTestDash = {
        { Mean = 4, Mad = 0.1, Samples = 3 },
        { Mean = 8, Mad = 0.1, Samples = 3 },
        { Mean = 13, Mad = 0.1, Samples = 3 },
    }
    local learned40 = State:CalibratedDashDistance("SelfTestDash", 0.04, 50)
    local learned80 = State:CalibratedDashDistance("SelfTestDash", 0.08, 50)
    local learned140 = State:CalibratedDashDistance("SelfTestDash", 0.14, 50)
    result.ConservativeDashCurve = learned40 > 0
        and learned40 <= learned80 and learned80 <= learned140
        and learned140 < 50
    State.DashCurveCalibration.SelfTestDash = nil
    State.CalibrationByKey.SelfTestImpact = nil
    result.BoundedMpc = MAX_MPC_DELAYS <= 4
        and MAX_PATH_HYPOTHESES <= 5
        and MAX_MPC_TESTS <= 2200
        and MPC_WORK_BUDGET <= 0.0035
    local controllerLook = Vector3.new(0, 0, -1)
    local controllerRight = controllerLook:Cross(Vector3.new(0, 1, 0))
    local forwardCode, forwardVector = self:ExecutableDashDirection(
        controllerLook,
        controllerLook + controllerRight
    )
    local backCode = self:ExecutableDashDirection(
        controllerLook,
        -controllerLook + controllerRight
    )
    local rightCode, rightVector = self:ExecutableDashDirection(
        controllerLook,
        controllerRight
    )
    local leftCode = self:ExecutableDashDirection(
        controllerLook,
        -controllerRight
    )
    result.ControllerDirectionParity = forwardCode == "Forward"
        and backCode == "Backwards"
        and rightCode == "Right"
        and leftCode == "Left"
        and forwardVector:Dot(controllerLook) > 0.999
        and rightVector:Dot(controllerRight) > 0.999
    local terrainEstimator = newEstimator(8, 0.2)
    terrainEstimator.Upper = 11
    terrainEstimator.Samples = 3
    self.DashCurveCalibration.SelfTestTerrain = {
        terrainEstimator,
        Dirty = true,
    }
    local terrainLower = self:CalibratedDashDistance(
        "SelfTestTerrain",
        0.04,
        10
    )
    local terrainUpper = self:CalibratedDashUpperDistance(
        "SelfTestTerrain",
        0.04,
        10
    )
    result.SeparateTerrainUpperEnvelope = terrainLower < 8
        and terrainUpper >= 11 and terrainUpper > terrainLower
    self.DashCurveCalibration.SelfTestTerrain = nil
    local barrierProbe = Instance.new("Folder")
    barrierProbe.Name = "Barriers"
    local barrierPart = Instance.new("Part")
    barrierPart.Parent = barrierProbe
    local ordinaryModel = Instance.new("Model")
    ordinaryModel.Name = "Model_123"
    local ordinaryPart = Instance.new("Part")
    ordinaryPart.Parent = ordinaryModel
    local hazardProbe = Instance.new("Folder")
    hazardProbe.Name = "KillBrick"
    local hazardPart = Instance.new("Part")
    hazardPart.Parent = hazardProbe
    result.GeometryRoleClassification = self:IsBarrierGeometry(barrierPart)
        and not self:IsBarrierGeometry(ordinaryPart)
        and self:IsHazardGeometry(hazardPart)
        and not self:IsHazardGeometry(ordinaryPart)
    barrierProbe:Destroy()
    ordinaryModel:Destroy()
    hazardProbe:Destroy()
    result.BoundedGroundSweep = self.GroundProbeSpacing <= 1.5
        and self.MaximumGroundSamples <= 20
        and self.GroundFootprintRadius >= 1.5
        and self.MaximumAdaptiveGroundSpacing >= self.GroundProbeSpacing
        and self.MaximumAdaptiveGroundSpacing <= 2
        and self.PhantomGroundMinimumNormalY >= 0.7
    local phantomReady0, phantomMaximum = self:PhantomReadyCharges(0, false)
    local phantomReady1 = self:PhantomReadyCharges(1, false)
    local phantomReady2 = self:PhantomReadyCharges(2, false)
    local phantomSingleReady = self:PhantomReadyCharges(0, true)
    local phantomSingleSpent = self:PhantomReadyCharges(2, true)
    result.PhantomChargeModel = phantomReady0 == 2
        and phantomMaximum == 2
        and phantomReady1 == 1
        and phantomReady2 == 0
        and phantomSingleReady == 1
        and phantomSingleSpent == 0
    local phantomAt40ms = self:PhantomStepDistance(6, 1, 0.04)
    local phantomAt50ms = self:PhantomStepDistance(6, 1, 0.05)
    local phantomAt500ms = self:PhantomStepDistance(6, 1, 0.5)
    result.PhantomTrajectory = math.abs(phantomAt40ms - 8.4672) < 0.0001
        and math.abs(phantomAt50ms - 10.584) < 0.0001
        and math.abs(phantomAt500ms - phantomAt50ms) < 0.0001
    result.ExactPhantomTerrainEnvelope = self.PhantomTerrainSafetyScale >= 1
        and self.PhantomTerrainSafetyScale <= 1.2
        and phantomAt500ms * self.PhantomTerrainSafetyScale
            + self.TerrainTravelMargin > phantomAt500ms
    local flingProbe = {
        Direction = Vector3.new(1, 0, 0),
        ExpectedPeakSpeed = 220,
        ExpectedTravel = 11,
        StartPosition = ZERO,
        StartedAt = 0,
    }
    local normalDash = self:DashFlingReason(
        flingProbe,
        Vector3.new(220, 0, 0),
        ZERO,
        Vector3.new(10, 0, 0),
        0.05
    )
    local cameraSteeredDash = self:DashFlingReason(
        flingProbe,
        Vector3.new(0, 0, 220),
        ZERO,
        Vector3.new(0, 0, 10),
        0.05
    )
    local verticalFling = self:DashFlingReason(
        flingProbe,
        Vector3.new(80, 100, 0),
        ZERO,
        Vector3.new(5, 4, 0),
        0.05
    )
    local displacementFling = self:DashFlingReason(
        flingProbe,
        Vector3.new(80, 0, 0),
        ZERO,
        Vector3.new(30, 0, 0),
        0.1
    )
    result.FlingClassifier = normalDash == nil
        and cameraSteeredDash == nil
        and verticalFling == "vertical launch"
        and displacementFling == "displacement overshoot"
    local passed = true
    for _, value in pairs(result) do
        if value ~= true then
            passed = false
            break
        end
    end
    result.Passed = passed
    self.LastSelfTest = result
    return result
end

local function startEngine(generation)
    if State.Engine then
        return
    end
    local signal = RunService.PreSimulation or RunService.Heartbeat
    State.Engine = signal:Connect(function(deltaTime)
        if not State.Enabled or State.Generation ~= generation then
            return
        end
        local ok, message = xpcall(
            processFrame,
            debug.traceback,
            deltaTime,
            generation
        )
        if not ok then
            reportError("prediction engine", message)
        end
    end)
end

local function stopActiveWork()
    State.Initializing = false
    restoreDirectionLease(nil, false)
    disconnect(State.Engine)
    State.Engine = nil
    disconnect(State.ProjectileEffectsConnection)
    State.ProjectileEffectsConnection = nil
    clearConnections(State.ActiveConnections)
    for _, watcher in pairs(State.Watchers) do
        disconnect(watcher.AnimationConnection)
        disconnect(watcher.DescendantAddedConnection)
        disconnect(watcher.DescendantRemovingConnection)
    end
    table.clear(State.Watchers)
    table.clear(State.Pending)
    table.clear(State.PendingIndex)
    table.clear(State.RecentEnemyDashes)
    table.clear(State.TopThreats)
    table.clear(State.Projectiles)
    table.clear(State.ProjectileList)
    table.clear(State.DashTelemetry)
    State.DashSafety = nil
    State.FlingBrakeUntil = 0
    State.SeenTracks = setmetatable({}, { __mode = "k" })
    State.LocalMotion = nil
    State.AttemptPending = nil
    State.DodgePlan = nil
    State.NextMpcAt = 0
    table.clear(State.RequestTimes)
    State.LastRequestAt = -math.huge
    State.LastAcceptedAt = -math.huge
    table.clear(State.ShadowAnimations)
    State.ShadowAnimationCount = 0
    State.WatcherCount = 0
    State.PendingCount = 0
    State.ProjectileCount = 0
    State.NextProjectileRescanAt = 0
    State.FrameDeadline = 0
    State.LastProcessAt = nil
    State.LastBlockReason = "None"
    State.DashCalibrationKeyCharacter = nil
    State.DashCalibrationKeyValue = nil
    State.DashCalibrationKeyPhantom = nil
    State.DashCalibrationKeyExpiresAt = 0
end

function State:SetEnabled(enabled)
    if self.Destroyed then
        return
    end
    enabled = enabled == true
    if self.Enabled == enabled then
        return
    end

    self.Generation += 1
    self.Enabled = false
    stopActiveWork()
    if enabled then
        self.Initializing = true
        self.Enabled = true
        self.ConsecutiveErrors = 0
        local generation = self.Generation
        local ok, message = xpcall(function()
            buildProfiles(true)
            for _, character in ipairs(Live:GetChildren()) do
                watchCharacter(character, generation)
            end
            self.ActiveConnections[#self.ActiveConnections + 1] =
                Live.ChildAdded:Connect(guarded("live added", function(character)
                    if State.Enabled and State.Generation == generation then
                        watchCharacter(character, generation)
                    end
                end))
            self.ActiveConnections[#self.ActiveConnections + 1] =
                Live.ChildRemoved:Connect(guarded("live removed", function(character)
                    if State.Generation == generation then
                        disconnectWatcher(character)
                    end
                end))
            self.ActiveConnections[#self.ActiveConnections + 1] =
                LocalPlayer.CharacterAdded:Connect(guarded(
                    "local respawn",
                    function(character)
                        if State.Enabled and State.Generation == generation then
                            restoreDirectionLease(nil, false)
                            State.LocalMotion = nil
                            State.AttemptPending = nil
                            State.DodgePlan = nil
                            State:ClearDashControllerCache()
                            State:ResetPhantomFallback(character)
                            table.clear(State.DashTelemetry)
                            State.DashCalibrationKeyCharacter = nil
                            State.DashCalibrationKeyValue = nil
                            State.DashCalibrationKeyPhantom = nil
                            State.DashCalibrationKeyExpiresAt = 0
                            State.LastAcceptedAt = -math.huge
                            State.LastRequestAt = -math.huge
                            table.clear(State.RequestTimes)
                            disconnectWatcher(character)
                        end
                    end
                ))
            startProjectileTracking(generation)
            self.NextPingSampleAt = 0
            self.NextServerClockSampleAt = os.clock()
                + PING_SAMPLE_INTERVAL * 0.5
            if self:IsPhantomStepActive(LocalPlayer.Character) then
                self:GetPhantomCharges(LocalPlayer.Character, os.clock())
            end
            startEngine(generation)
        end, debug.traceback)
        self.Initializing = false
        if not ok then
            self.Enabled = false
            self.Generation += 1
            stopActiveWork()
            reportError("activation", message)
        end
    end
    updateStatus(true)
end

function State:Destroy()
    if self.Destroyed then
        return
    end
    self.Destroyed = true
    self.Generation += 1
    self.Enabled = false
    stopActiveWork()
    clearConnections(self.LifetimeConnections)
    if StatusGui then
        StatusGui:Destroy()
    end
    self.Profiles = nil
    self.DashIds = nil
    self:ClearDashControllerCache()
    self:ResetPhantomFallback(nil)
    table.clear(self.DynamicProfiles)
    table.clear(self.ShadowAnimations)
    table.clear(self.CalibrationByKey)
    table.clear(self.DashCurveCalibration)
    table.clear(self.DashTelemetry)
    table.clear(self.Replay)
    self.DynamicProfileCount = 0
    self.ShadowAnimationCount = 0
    self.ReplayCount = 0
    self.ReplayHead = 0
    if Environment.__INK_GAME_AUTO_DODGE == self then
        Environment.__INK_GAME_AUTO_DODGE = nil
    end
end

State.LifetimeConnections[#State.LifetimeConnections + 1] =
    UserInputService.InputBegan:Connect(guarded("toggle", function(input, processed)
        if not processed and input.KeyCode == State.ToggleKey
            and not UserInputService:GetFocusedTextBox() then
            State:SetEnabled(not State.Enabled)
        end
    end))

updateStatus(true)
warn("[Ink Auto Dodge] Belief-space intent ensemble v7.3 loaded OFF - press F1 to enable")
