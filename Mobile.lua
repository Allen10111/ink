-- Ink Game auto dodge v8.04 Mobile
-- Tap the draggable circle to toggle. Red OFF; green ON. Starts OFF.
-- No intentional reaction wait after first confirmed threat contact.
-- Native dash event only; no synthetic keyboard input or intentional reaction wait.
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
--   * Prediction uses a shared deadline; terrain has a bounded separate reserve.
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
local MAX_DIRECTION_THREATS = 12
local MAX_DIRECTION_CANDIDATES = 12
local MAX_DIRECTION_SAMPLES = 16
local MAX_SWEEP_STEPS = 20
local MAX_PREDICTION_TIME = 1.35
local MAX_MPC_DELAYS = 1
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
local MPC_REPLAN_INTERVAL = 0.04
local MPC_WORK_BUDGET = 0.0035
local POST_DODGE_HORIZON = 0.62
local NEAR_SAMPLE_RANGE = 180
local PROJECTILE_ACQUISITION_RANGE = 260
local PROJECTILE_HARD_TTL = 6
local PROJECTILE_MOTION_PROBATION = 1
local PROJECTILE_PROOF_SPEED = 3
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
    Version = 8.04,
    MobileVersion = true,
    MinimumActionPlanningBudget = 0.0018,
    PlanningReserveUses = 0,
    LocalRestCorrections = 0,
    EnableMotionEstimator = true,
    EnableAdaptiveSampling = true,
    EnableEmpiricalTiming = true,
    EnableFollowupPlanning = true,
    TimingSamples = {},
    LastEmpiricalLead = 0,
    AdaptiveSamples = 0,
    AdaptiveHits = 0,
    EstimatorUpdates = 0,
    EstimatorRapidUpdates = 0,
    FollowupCompleted = 0,
    FollowupDeferred = 0,
    LastFollowupMode = "Not evaluated",
    LastFollowupOptions = 0,
    LastGroupThreatCount = 0,
    LastGroupSourceCount = 0,
    LastGroupCoverageComplete = false,
    LastGroupStatus = "No group decision",
    GroupIncompleteBlocks = 0,
    NativeSharedFunctions = nil,
    NativeModel = nil,
    NativeModelCharacter = nil,
    NativeModelSignature = nil,
    NativeBoostExpiresAt = 0,
    NativeBoostSource = "Not sampled",
    NativeCancellationCharacter = nil,
    NativeCancellationConnection = nil,
    NativeBurstStopFrameMargin = 1 / 30,
    HitboxModuleEvidence = "Modules.Hitbox: part overlap; Modules.HB: box bounds, opt-in velocity prediction; call-site parameters required",
    AttackAudit = {},
    AttackAuditCount = 0,
    AuditDroppedProfiles = 0,
    AuditBlocks = {},
    AuditBlockCount = 0,
    DodgeAudit = {},
    DodgeAuditHead = 0,
    DodgeAuditCount = 0,
    DodgeAuditSerial = 0,
    PendingDodgeAudits = {},
    AuditHealthConnection = nil,
    AuditHumanoid = nil,
    LastEvidenceTier = "No observation",
    LastDodgeOutcome = "No observation",
    TerrainResultCache = {},
    TerrainCacheHits = 0,
    TerrainCacheMisses = 0,
    Enabled = false,
    Initializing = false,
    Destroyed = false,
    Generation = 0,
    ToggleKey = Enum.KeyCode.F1,
    GuiVisible = true,
    PhantomStepPower = "PHANTOM STEP",
    PhantomStepDuration = 0.05,
    PhantomStepDirectionScale = 7,
    PhantomStepBaseSpeed = 27,
    PhantomStepMaxStacks = 2,
    PhantomStackClearGrace = 0.12,
    PhantomSettleInterval = 0.12,
    DashWalkConfirmMinSpeed = 6,
    DashForwardFacingDot = 0.7,
    DashRetryWindow = 0.12,
    DashRetryMaximum = DASH_LINK_WINDOW,
    MaxDeferredDashAttacks = 3,
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
    TerrainPlanningBudget = 0.003,
    TerrainRouteBudget = 0.0015,
    TerrainPreflightBudget = 0.003,
    TerrainDeferredChecks = 0,
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
    MaximumGroundSamples = 20, -- Preferred segment count, not a distance cutoff.
    MaximumExtendedGroundSamples = 96, -- Hard work cap; deadlines still apply.
    TerrainCoverageRetryInterval = 0.05,
    MaximumDashTelemetryGap = 0.08,
    LastGroundTravel = 0,
    LastGroundCoverageLimit = 0,
    LastGroundSegments = 0,
    LastGroundSpacing = 0,
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
    MpcTerrainBudgetFraction = 0.4,
    -- The native controller has exactly four executable cardinal outcomes.
    -- Terrain validation must never discard one before it is checked.
    MaxMpcTerrainHeadings = 4,
    MaxFastMpcTerrainHeadings = 4,
    MaxMpcRobustControls = 4,
    MinimumMpcCoarseControls = 8,
    ComboTailHorizon = 1.9,
    MapScanPerFrame = 384,
    MapMotionSamplesPerFrame = 96,
    MapHazardSweepLimit = 512,
    MapMotionMaximumAge = 2,
    MapRoleSignals = {
        "barrier", "kill", "death", "damage", "hazard", "lethal",
        "lava", "void", "breakaway", "fallingplatform", "trapdoor",
        "fakefloor", "unsafe", "disappear",
    },
    MapDynamicSignals = {
        "door", "gate", "platform", "moving", "spinner", "rotate",
        "elevator", "bridge", "trap", "breakaway", "falling",
    },

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
    MpcCoarseFallbacks = 0,
    MpcSolveCount = 0,
    LastMpcCompletedCandidates = 0,
    LastMpcBudgetReason = "None",
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
    ThreatPrioritySkips = 0,
    LastTerrainStatus = "Unchecked",
    MapRoots = {},
    EventMapRoots = {},
    EventMapMembership = setmetatable({}, { __mode = "k" }),
    MapConnections = {},
    MapRegistry = setmetatable({}, { __mode = "k" }),
    MapQueued = setmetatable({}, { __mode = "k" }),
    MapRoleCache = setmetatable({}, { __mode = "k" }),
    MapHazardMembership = setmetatable({}, { __mode = "k" }),
    MapBarrierMembership = setmetatable({}, { __mode = "k" }),
    MapDynamicMembership = setmetatable({}, { __mode = "k" }),
    MapHazardListed = setmetatable({}, { __mode = "k" }),
    MapBarrierListed = setmetatable({}, { __mode = "k" }),
    MapDynamicListed = setmetatable({}, { __mode = "k" }),
    MapMotion = setmetatable({}, { __mode = "k" }),
    MapPartList = {},
    MapHazardList = {},
    MapBarrierList = {},
    MapDynamicList = {},
    MapScanQueue = {},
    MapScanCursor = 1,
    MapScanTail = 0,
    MapMotionCursor = 1,
    MapDynamicCursor = 1,
    MapAuditTotal = 0,
    MapAuditScanned = 0,
    MapRegisteredCount = 0,
    MapAuditParts = 0,
    MapAuditModels = 0,
    MapAuditComplete = false,
    MapRevision = 0,
    MapChangedAt = 0,
    MapRevisionFrameToken = -1,
    MapMovingParts = 0,
    MapHazardCount = 0,
    MapBarrierCount = 0,
    MapDynamicCount = 0,
    MapRootCount = 0,
    MapTombstones = 0,
    LastFrameWork = 0,
    FrameWorkMean = 0,
    DecayingWorstWork = 0,
    FrameDeadline = 0,
    FrameBudgetActive = false,
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
    ProfileRefreshAttempts = 0,
    ProfileRefreshes = 0,
    RecentEnemyDashes = setmetatable({}, { __mode = "k" }),
    RecentEnemyDashDirections = setmetatable({}, { __mode = "k" }),
    RecentEnemyDashWalkBridgeUntil = setmetatable({}, { __mode = "k" }),
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
    DashDispatchMode = "Native event",
    FixedReactionMilliseconds = 0,
    ReactionLeadMilliseconds = 0, -- Additional prediction margin only.
    DirectionVerifiedDodges = 0,
    DirectionUnverifiedDodges = 0,
    LastDashDirectionDot = 0,
    LastDashDirectionDistance = 0,
    LastDashDirectionSpeed = 0,
    LastDashAckSource = "None",
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
    PhantomFallbackSuppressRecentDashUntil = 0,
    PhantomFallbackPowerActive = false,
    PhantomLastStackSource = "Inactive",
    PhantomFallbackRollbacks = 0,
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
    DashAvailabilityBlocks = 0,
    LastDashAvailabilityReason = "None",
    LastDashBlockReplayAt = -math.huge,
    LastDashBlockReplayReason = "None",
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
        if ok and type(value) == "string" then
            return value
        end
    end
    return LocalPlayer:GetAttribute("IsGuard") and LocalPlayer:GetAttribute("_EquippedGuardPower")
        or LocalPlayer:GetAttribute("_EquippedPower")
end

function State:IsPhantomStepActive(character)
    return self:GetEffectivePower(character) == self.PhantomStepPower
        and not getValue("PowersDisabled", false)
        and LocalPlayer:GetAttribute("IsGuard") ~= true
end

function State:DashDirectionVector(character, dashDirection, fallback)
    local function horizontal(value, fallbackValue)
        local vector = typeof(value) == "Vector3"
            and Vector3.new(value.X, 0, value.Z) or Vector3.zero
        if vector.Magnitude > 0.0001 then
            return vector.Unit
        end
        local fallbackVector = typeof(fallbackValue) == "Vector3"
            and Vector3.new(fallbackValue.X, 0, fallbackValue.Z)
            or Vector3.new(0, 0, -1)
        return fallbackVector.Magnitude > 0.0001
            and fallbackVector.Unit or Vector3.new(0, 0, -1)
    end
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local frame = root and root.CFrame
    local look = frame and horizontal(frame.LookVector, fallback)
        or horizontal(fallback or Vector3.new(0, 0, -1))
    local right = frame and horizontal(frame.RightVector, Vector3.new(1, 0, 0))
        or Vector3.new(-look.Z, 0, look.X)
    local directionName = string.lower(tostring(dashDirection or ""))
    if string.find(directionName, "back", 1, true) then
        return -look
    elseif string.find(directionName, "right", 1, true) then
        return right
    elseif string.find(directionName, "left", 1, true) then
        return -right
    end
    return look
end

function State:IsWalkDashAligned(
    walkBridgeActive,
    dashDirection,
    movementSpeed,
    directionDot
)
    -- A real cardinal dash animation can arrive one replication sample before
    -- its velocity. During that narrow gap, require ordinary locomotion plus
    -- strong world-space evidence that the *announced dash direction* points
    -- toward the local player. This covers walk+side/back dash attacks without
    -- accepting sideways or away dash animations as threats.
    local directionName = string.lower(tostring(dashDirection or ""))
    local recognized = string.find(directionName, "forward", 1, true)
        or string.find(directionName, "back", 1, true)
        or string.find(directionName, "right", 1, true)
        or string.find(directionName, "left", 1, true)
    return walkBridgeActive == true
        and recognized
        and (movementSpeed or 0) >= self.DashWalkConfirmMinSpeed
        and (directionDot or -1) >= self.DashForwardFacingDot
end

function State:IsDashRetryFresh(candidate, now)
    return type(candidate) == "table"
        and candidate.Track ~= nil
        and candidate.Generation == self.Generation
        and type(candidate.At) == "number"
        and now - candidate.At >= 0
        and now - candidate.At <= math.clamp(
            math.max(
                self.DashRetryWindow,
                DASH_LINK_WINDOW,
                2 * (self.DecayingWorstFrame or self.FrameMean or 1 / 60)
                    + (self.PingDeviation or 0)
            ),
            self.DashRetryWindow,
            self.DashRetryMaximum
        )
end

function State:IsDashRetryTrackUsable(candidate, now)
    if not self:IsDashRetryFresh(candidate, now) then
        return false
    end
    local ok, playing = pcall(function()
        return candidate.Track.IsPlaying
    end)
    if ok and playing then
        return true
    end
    local stoppedTrackGrace = math.clamp(
        math.max(0.04, 2 * (self.DecayingWorstFrame or self.FrameMean)),
        0.04,
        0.08
    )
    return candidate.WasPlaying == true
        and now - candidate.At <= stoppedTrackGrace
end

function State:StoreDeferredDashAttack(watcher, candidate)
    if type(watcher) ~= "table" or type(candidate) ~= "table" then
        return false
    end
    local now = candidate.At or os.clock()
    local deferred = watcher.DeferredDashAttacks
    if type(deferred) ~= "table" then
        deferred = table.create(self.MaxDeferredDashAttacks)
        watcher.DeferredDashAttacks = deferred
    end
    for index = #deferred, 1, -1 do
        local existing = deferred[index]
        if not self:IsDashRetryFresh(existing, now)
            or existing.Track == candidate.Track then
            table.remove(deferred, index)
        end
    end
    deferred[#deferred + 1] = candidate
    while #deferred > self.MaxDeferredDashAttacks do
        table.remove(deferred, 1)
    end
    return true
end

function State:TakeDeferredDashAttacks(watcher, now)
    local deferred = watcher and watcher.DeferredDashAttacks
    if type(deferred) ~= "table" then
        return {}
    end
    watcher.DeferredDashAttacks = nil
    local retries = table.create(math.min(
        #deferred,
        self.MaxDeferredDashAttacks
    ))
    for index = 1, #deferred do
        local candidate = deferred[index]
        if self:IsDashRetryTrackUsable(candidate, now) then
            retries[#retries + 1] = candidate
        end
    end
    return retries
end

function State:RemoveDeferredDashAttack(watcher, track)
    local deferred = watcher and watcher.DeferredDashAttacks
    if type(deferred) ~= "table" then
        return
    end
    for index = #deferred, 1, -1 do
        if deferred[index].Track == track then
            table.remove(deferred, index)
        end
    end
    if #deferred == 0 then
        watcher.DeferredDashAttacks = nil
    end
end

function State:PruneDeferredDashAttacks(now)
    for _, watcher in pairs(self.Watchers) do
        local deferred = watcher.DeferredDashAttacks
        if type(deferred) == "table" then
            for index = #deferred, 1, -1 do
                if not self:IsDashRetryFresh(deferred[index], now) then
                    table.remove(deferred, index)
                end
            end
            if #deferred == 0 then
                watcher.DeferredDashAttacks = nil
            end
        end
    end
end

function State:DashCandidateAcquisitionRange(baseReach, activeHorizon)
    local horizon = math.clamp(activeHorizon or 0, 0, MAX_PREDICTION_TIME)
    return math.min(
        NEAR_SAMPLE_RANGE,
        (baseReach or 0) + BODY_RADIUS + QUEUE_MARGIN
            + 140 * horizon
            + 0.5 * 320 * horizon * horizon
    )
end

function State:ProvisionalForwardDashDistance(character, timeAhead)
    local swingSpeed = character and character:FindFirstChild("SwingSpeed")
    local multiplier = swingSpeed and swingSpeed.Value or 1
    local time = math.clamp(timeAhead or 0, 0, 0.5)
    if time <= 0.1 then
        return 113.75 * multiplier * time
    end

    -- Exact integral of the normal dash controller's first 0.5 seconds:
    -- 113.75 studs/s for 0.1s, followed by its cubic 60-stud/s decay.
    local phase = (time - 0.1) / 0.4
    local decayIntegral = phase
        - 0.3 * phase * phase
        - 0.4 * phase * phase * phase
        + 0.2 * phase * phase * phase * phase
    return multiplier * (11.375 + 24 * decayIntegral)
end

function State:ProvisionalDashOffset(threat, attackerMotion, timeAhead)
    if not threat or not threat.ProvisionalDash
        or (threat.ProvisionalDashExpiresAt or 0) < os.clock() then
        return ZERO
    end
    local sourceDirection = threat.ProvisionalDashDirection
        or threat.LookDirection or Vector3.new(0, 0, -1)
    local direction = Vector3.new(sourceDirection.X, 0, sourceDirection.Z)
    if direction.Magnitude <= 0.0001 then
        direction = Vector3.new(0, 0, -1)
    else
        direction = direction.Unit
    end
    local velocity = attackerMotion
        and (attackerMotion.ShortVelocity or attackerMotion.Velocity) or ZERO
    local baselineDistance = math.max(0, velocity:Dot(direction))
        * math.max(0, timeAhead or 0)
    local nativeDistance = self:ProvisionalForwardDashDistance(
        threat.Character,
        timeAhead
    )
    return direction * math.max(0, nativeDistance - baselineDistance)
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
    self.PhantomFallbackSuppressRecentDashUntil = 0
    self.PhantomLastStackSource = "Fallback"
    -- If the script starts while recovery is already active and the exact
    -- controller table is unavailable, block conservatively until it clears.
    self.PhantomFallbackStacks = self.PhantomFallbackMarkerSeen
        and self.PhantomStepMaxStacks or 0
end

function State:GetPhantomStackCount(character, now)
    local controllerState = self:ResolveDashControllerState(character)
    if controllerState then
        local exactStacks = math.clamp(
            math.floor((rawget(controllerState, "CDDASHSTACKS") or 0) + 0.5),
            0,
            self.PhantomStepMaxStacks
        )
        -- Keep fallback state synchronized while the exact controller is
        -- available.  If its cached connection later invalidates, fallback
        -- starts from the last real state instead of stale pre-controller data.
        self.PhantomFallbackCharacter = character
        self.PhantomFallbackRecentDash = character
            and character:GetAttribute("RecentDash") or nil
        self.PhantomFallbackStacks = exactStacks
        self.PhantomFallbackMarkerSeen = character
            and character:FindFirstChild("CDDASHSTACKSCD") ~= nil or false
        self.PhantomFallbackMarkerClearedAt = nil
        self.PhantomFallbackSuppressRecentDashUntil = 0
        self.PhantomLastStackSource = "Controller"
        return exactStacks, "Controller"
    end

    if self.PhantomFallbackCharacter ~= character then
        self:ResetPhantomFallback(character)
    end
    self.PhantomLastStackSource = "Fallback"
    local recentDash = character and character:GetAttribute("RecentDash")
    if type(recentDash) == "number"
        and recentDash ~= self.PhantomFallbackRecentDash then
        self.PhantomFallbackRecentDash = recentDash
        if now <= (self.PhantomFallbackSuppressRecentDashUntil or 0) then
            -- The fallback path already accounted for this native request at
            -- Info:Fire time.  Consume the matching RecentDash edge without
            -- charging it twice when that attribute replicates a frame later.
            self.PhantomFallbackSuppressRecentDashUntil = 0
        else
            local spent = self:PhantomUsesSingleChargeMode()
                and self.PhantomStepMaxStacks or 1
            self.PhantomFallbackStacks = math.min(
                self.PhantomStepMaxStacks,
                self.PhantomFallbackStacks + spent
            )
        end
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

function State:RecordPhantomFallbackSpend(
    character,
    source,
    now,
    beforeRecentDash
)
    if source == "Controller" or not character then
        return 0
    end
    if self.PhantomFallbackCharacter ~= character then
        self:ResetPhantomFallback(character)
    end
    local spent = self:PhantomUsesSingleChargeMode()
        and self.PhantomStepMaxStacks or 1
    local beforeStacks = self.PhantomFallbackStacks
    self.PhantomFallbackStacks = math.min(
        self.PhantomStepMaxStacks,
        self.PhantomFallbackStacks + spent
    )
    local postRecentDash = character:GetAttribute("RecentDash")
    self.PhantomFallbackRecentDash = postRecentDash
    self.PhantomFallbackSuppressRecentDashUntil =
        postRecentDash == beforeRecentDash
            and (now or os.clock()) + 0.35 or 0
    return self.PhantomFallbackStacks - beforeStacks
end

function State:RollbackPhantomFallbackSpend(
    character,
    spent,
    beforeRecentDash
)
    spent = tonumber(spent) or 0
    if spent <= 0 or not character
        or self.PhantomFallbackCharacter ~= character
        or self:ResolveDashControllerState(character) then
        return false
    end
    local recentDash = character:GetAttribute("RecentDash")
    if character:FindFirstChild("CDDASHSTACKSCD")
        or recentDash ~= beforeRecentDash then
        return false
    end
    self.PhantomFallbackStacks = math.max(
        0,
        self.PhantomFallbackStacks - spent
    )
    self.PhantomFallbackRecentDash = recentDash
    self.PhantomFallbackSuppressRecentDashUntil = 0
    self.PhantomFallbackRollbacks += 1
    return true
end

function State:GetPhantomCharges(character, now)
    if not character or not self:IsPhantomStepActive(character) then
        self.PhantomFallbackPowerActive = false
        self.PhantomChargesReady = 0
        self.PhantomChargesMax = 0
        self.PhantomStateSource = "Inactive"
        return 0, 0, "Inactive"
    end
    if not self.PhantomFallbackPowerActive then
        -- A normal dash may change RecentDash while another power is active.
        -- Establish a fresh baseline on the Phantom equip edge so that stale
        -- normal-dash state can never be counted as a Phantom charge spend.
        self:ResetPhantomFallback(character)
        self.PhantomFallbackPowerActive = true
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
    if not character then
        return false, "No local character", 0, 0, 0, "Inactive"
    end
    if character.Parent ~= Live then
        return false, "Character outside Live", 0, 0, 0, "Inactive"
    end
    if not humanoid then
        return false, "Humanoid unavailable", 0, 0, 0, "Inactive"
    end
    if humanoid.Health <= 0 then
        return false, "Humanoid dead", 0, 0, 0, "Inactive"
    end
    if character:FindFirstChild("DisableDash") then
        return false, "DisableDash marker", 0, 0, 0, "Native"
    end
    local stunReason = State:NativeDashStunReason(character)
    if stunReason then return false, stunReason, 0, 0, 0, "Native" end
    if character:FindFirstChild("Dead") then
        return false, "Dead marker", 0, 0, 0, "Native"
    end
    if character:FindFirstChild("Ragdoll") then
        return false, "Ragdoll marker", 0, 0, 0, "Native"
    end
    if getValue("CurrentGame", "") == "GlassBridge"
        and not character:GetAttribute("InSurgery") then
        return false, "Glass Bridge dash disabled", 0, 0, 0, "Native"
    end

    local boosts = LocalPlayer:FindFirstChild("Boosts")
    local fasterSprint = boosts and boosts:FindFirstChild("Faster Sprint")
    local phantomStep = State:IsPhantomStepActive(character)
    local unlocked = fasterSprint and fasterSprint.Value >= 5
        or workspace:GetAttribute("MaxSpeedBoosts")
        or phantomStep
    if not unlocked then
        return false, "Dash not unlocked", 0, 0, 0, "Native"
    end

    local nativeController = State:ResolveDashControllerState(character)
    if nativeController and (nativeController.DidEffect or nativeController.DashZoomIn) then
        return false, "Manual dash charge active", 0, 0, 0, "Controller"
    end
    if phantomStep then
        local ready, maximum, source = State:GetPhantomCharges(
            character,
            os.clock()
        )
        if ready <= 0 then
            return false, "Phantom charges empty", 0,
                ready, maximum, source
        end
        return true, "Ready", 0, ready, maximum, source
    end

    local ready, reason, remaining, source = State:NativeNormalCooldown(character, os.clock())
    return ready, reason, remaining, 0, 0, source
end

local StatusGui = Instance.new("ScreenGui")
StatusGui.Name = "InkAutoDodgeMobile"
StatusGui.ResetOnSpawn = false
StatusGui.IgnoreGuiInset = false
StatusGui.DisplayOrder = 1000000
StatusGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
StatusGui.Parent = LocalPlayer:WaitForChild("PlayerGui")
do
    local area = Instance.new("Frame")
    area.Name = "DragArea"
    area.Size = UDim2.fromScale(1, 1)
    area.BackgroundTransparency = 1
    area.BorderSizePixel = 0
    area.Active = false
    area.Parent = StatusGui

    local button = Instance.new("TextButton")
    button.Name = "Toggle"
    button.Size = UDim2.fromOffset(64, 64)
    button.Position = UDim2.new(0.82, 0, 0.28, 0)
    button.Text = ""
    button.AutoButtonColor = false
    button.BackgroundColor3 = Color3.fromRGB(164, 55, 62)
    button.BorderSizePixel = 0
    button.Active = true
    button.Selectable = false
    button.Parent = area

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = button
    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(235, 240, 250)
    stroke.Thickness = 2
    stroke.Transparency = 0.15
    stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    stroke.Parent = button
    State.ToggleButton = button
    State.MobileDragArea = area
end

function State:ClampMobilePosition(position)
    local size = self.MobileDragArea.AbsoluteSize
    local buttonSize = self.ToggleButton.AbsoluteSize
    local margin = 10
    local maxX = math.max(0, size.X - buttonSize.X - margin)
    local maxY = math.max(0, size.Y - buttonSize.Y - margin)
    return Vector2.new(
        math.clamp(position.X, math.min(margin, maxX), maxX),
        math.clamp(position.Y, math.min(margin, maxY), maxY)
    )
end

function State:PlaceMobileButton(position)
    if self.Destroyed or self.MobileDragArea.AbsoluteSize.X <= 0 then return end
    local point = self:ClampMobilePosition(position)
    self.ToggleButton.Position = UDim2.fromOffset(point.X, point.Y)
end

function State:BeginMobilePointer(input)
    if self.Destroyed or self.MobilePointer then return false end
    local kind = input.UserInputType
    if kind ~= Enum.UserInputType.Touch and kind ~= Enum.UserInputType.MouseButton1 then return false end
    self.MobilePointer = input
    self.MobilePointerStart = Vector2.new(input.Position.X, input.Position.Y)
    self.MobileButtonStart = self.ToggleButton.AbsolutePosition - self.MobileDragArea.AbsolutePosition
    self.MobileDragging = false
    return true
end

function State:MoveMobilePointer(input)
    local pointer = self.MobilePointer
    if self.Destroyed or not pointer then return false end
    if pointer.UserInputType == Enum.UserInputType.Touch then
        if input ~= pointer then return false end
    elseif input.UserInputType ~= Enum.UserInputType.MouseMovement then
        return false
    end
    local point = Vector2.new(input.Position.X, input.Position.Y)
    local delta = point - self.MobilePointerStart
    if delta.Magnitude >= 8 then self.MobileDragging = true end
    if self.MobileDragging then self:PlaceMobileButton(self.MobileButtonStart + delta) end
    return self.MobileDragging
end

function State:EndMobilePointer(input)
    if input ~= self.MobilePointer then return false end
    self.MobileLastReleasedInput = input
    if self.MobileDragging then self.MobileBlockTapUntil = os.clock() + 0.25 end
    self.MobilePointer = nil
    self.MobileDragging = false
    return true
end

function State:ActivateMobileToggle(input)
    if self.Destroyed or self.MobileDragging
        or os.clock() < (self.MobileBlockTapUntil or 0) then return false end
    -- Another finger can operate the joystick without becoming the toggle.
    if input and input.UserInputType == Enum.UserInputType.Touch
        and input ~= self.MobileLastReleasedInput and input ~= self.MobilePointer then return false end
    self:SetEnabled(not self.Enabled)
    return true
end

function State:BindMobileToggle()
    local function bind(signal, callback)
        self.LifetimeConnections[#self.LifetimeConnections + 1] = signal:Connect(callback)
    end
    local button = self.ToggleButton
    bind(button.InputBegan, function(input) self:BeginMobilePointer(input) end)
    bind(UserInputService.InputChanged, function(input) self:MoveMobilePointer(input) end)
    bind(UserInputService.InputEnded, function(input) self:EndMobilePointer(input) end)
    bind(button.Activated, function(input) self:ActivateMobileToggle(input) end)
    bind(self.MobileDragArea:GetPropertyChangedSignal("AbsoluteSize"), function()
        -- Reset gesture coordinates on rotation/resizing; never toggle on resize.
        self.MobilePointer = nil
        self.MobileDragging = false
        self.MobileBlockTapUntil = os.clock() + 0.25
        self:PlaceMobileButton(button.AbsolutePosition - self.MobileDragArea.AbsolutePosition)
    end)
    task.defer(function()
        self:PlaceMobileButton(button.AbsolutePosition - self.MobileDragArea.AbsolutePosition)
    end)
end

local function updateStatus(force)
    if State.Destroyed or not State.ToggleButton.Parent then return end
    State.ToggleButton.BackgroundColor3 = State.Enabled
        and Color3.fromRGB(36, 165, 91) or Color3.fromRGB(164, 55, 62)
    StatusGui.Enabled = true
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

function State:RecordDashAvailabilityBlock(
    threat,
    now,
    reason,
    remaining,
    ready,
    maximum,
    source
)
    reason = reason or "Native dash unavailable"
    self.LastBlockReason = reason
    self.LastDashAvailabilityReason = reason
    local changed = reason ~= self.LastDashBlockReplayReason
    if not changed and now - self.LastDashBlockReplayAt < 0.35 then
        return
    end
    self.LastDashBlockReplayReason = reason
    self.LastDashBlockReplayAt = now
    self.DashAvailabilityBlocks += 1
    self:RecordAuditBlock(threat, reason, now)
    pushReplay("dash_blocked", now, {
        Threat = threat and threat.Profile and threat.Profile.Name or "None",
        Reason = reason,
        Remaining = remaining or 0,
        Ready = ready or 0,
        Maximum = maximum or 0,
        Source = source or "Unknown",
        Contact = threat and threat.ContactIn or -1,
    })
end

function State:DashAcknowledgementReady(attempt, now, directionVerified)
    return directionVerified == true
        or attempt and attempt.Acknowledged == true
            and type(attempt.VerificationExpiresAt) == "number"
            and now >= attempt.VerificationExpiresAt
        or false
end

function State:PreserveDashVerificationGrace(attempt, now)
    if not attempt or type(attempt.VerificationExpiresAt) ~= "number" then
        return
    end
    attempt.ExpiresAt = math.max(
        attempt.ExpiresAt or now,
        attempt.VerificationExpiresAt
            + math.max(self.FrameMean, 1 / 240)
    )
end

function State:DashMotionVerified(
    projectedDistance,
    projectedSpeed,
    displacementDot,
    velocityDot,
    elapsed
)
    local averageProjectedSpeed = projectedDistance
        / math.max(elapsed or 0, 0.001)
    return projectedDistance >= 1.25
            and averageProjectedSpeed >= 32
            and displacementDot >= 0.7
        or projectedSpeed >= 40 and velocityDot >= 0.7
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

-- Evidence and outcomes are observations, never automatic proof of a server hit.
function State:EvidenceTier(threat)
    local id = normalizeAnimationId(threat and threat.TimingKey)
    if threat and threat.PhysicalProjectile then
        return "Tracked projectile"
    elseif id and self.ConfirmedHBProfiles and self.ConfirmedHBProfiles[id]
        and threat.Profile and threat.Profile.Kind ~= "Ranged" then
        return "Call-site hitbox"
    elseif threat and threat.WeaponSample then
        return "Live weapon geometry"
    elseif threat and threat.Profile and threat.Profile.Learned then
        return "Learned timing"
    end
    return "Timing profile"
end

function State:AuditProfile(threat)
    if not threat or not threat.Profile then return nil end
    local key = string.sub(tostring(threat.TimingKey or threat.Profile.Name or "Unknown"), 1, 80)
    local row = self.AttackAudit[key]
    if not row then
        if self.AttackAuditCount >= 128 then
            self.AuditDroppedProfiles += 1
            return nil
        end
        row = {
            Id = key, Name = string.sub(threat.Profile.Name or "Unknown", 1, 64),
            Observed = 0, Cancelled = 0, Predicted = 0, Requests = 0,
            Acknowledged = 0, MotionVerified = 0, DamageWindows = 0,
            ClearWindows = 0, InconclusiveWindows = 0,
            ExpectedActiveStart = threat.Profile.ActiveStart or 0,
            ExpectedActiveEnd = threat.Profile.ActiveEnd or 0,
            ExpectedRange = threat.Profile.Range or 0,
        }
        self.AttackAudit[key] = row
        self.AttackAuditCount += 1
    end
    row.Evidence = self:EvidenceTier(threat)
    self.LastEvidenceTier = row.Evidence
    return row
end

function State:ObserveAttackAudit(threat)
    if threat.AuditObserved then return end
    threat.AuditObserved = true
    local row = self:AuditProfile(threat)
    if not row then return end
    row.Observed += 1
    row.LastAnimationPhase = math.max(0, threat.LogicalElapsed or 0)
    row.LastPlaybackSpeed = threat.PlaybackSpeed or 1
    local track = threat.Track
    if track and track.Length > 0 then row.LastAnimationLength = track.Length end
end

function State:ObserveCancellationAudit(threat)
    if threat.AuditCancelled then return end
    threat.AuditCancelled = true
    local row = self:AuditProfile(threat)
    if row then
        row.Cancelled += 1
        row.LastCancelledPhase = threat.StoppedPhase or 0
    end
end

function State:ObservePredictionAudit(threat)
    local row = self:AuditProfile(threat)
    if row then row.Predicted += 1 end
end

function State:RecordAuditBlock(threat, reason, now)
    local key = string.sub(tostring(reason or "Unknown"), 1, 64)
    if string.sub(key, 1, 22) == "Ground coverage budget" then key = "Ground coverage budget" end
    local blocks = self.AuditBlocks
    local entry = blocks[key]
    if not entry then
        if self.AuditBlockCount >= 32 then return end
        entry = { Reason = key, Count = 0 }
        blocks[key] = entry
        self.AuditBlockCount += 1
    end
    entry.Count += 1
    entry.LastAt = now
    local row = self:AuditProfile(threat)
    if row then
        row.Blocks = (row.Blocks or 0) + 1
        row.LastBlock = key
    end
end

function State:BindAuditHealth(character)
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if self.AuditHumanoid == humanoid and self.AuditHealthConnection then return end
    disconnect(self.AuditHealthConnection)
    self.AuditHealthConnection = nil
    self.AuditHumanoid = humanoid
    if not humanoid then return end
    local last = humanoid.Health
    self.AuditHealthConnection = humanoid.HealthChanged:Connect(function(health)
        local loss = math.max(0, last - health)
        last = health
        if not self.Enabled or loss <= 0 then return end
        local now = os.clock()
        for _, record in ipairs(self.PendingDodgeAudits) do
            if record.Character == character and now <= record.EndsAt then
                record.HealthLoss += loss
            end
        end
    end)
end

function State:FinishDodgeAudit(record, now, interrupted)
    if record.Finished then return end
    record.Finished = true
    local row = self.AttackAudit[record.ProfileId]
    -- A quiet health window cannot establish which attack missed or why.
    local outcome = interrupted and "Inconclusive"
        or record.HealthLoss > 0 and "Health loss observed"
        or record.ObservationGap and "Inconclusive"
        or "No health loss observed"
    if row then
        if outcome == "Health loss observed" then row.DamageWindows += 1
        elseif outcome == "No health loss observed" then row.ClearWindows += 1
        else row.InconclusiveWindows += 1 end
    end
    local resolution=self:OutcomeResolution(record,interrupted)
    local eligible=not interrupted and not record.NativeCancelled and not record.ObservationGap
        and not record.Overlapping and record.Acknowledged and record.MotionVerified
    if row then
        if eligible then
            row.MeasuredWindows=(row.MeasuredWindows or 0)+1
            row.MeasuredHealthLosses=(row.MeasuredHealthLosses or 0)+(record.HealthLoss>0 and 1 or 0)
        else row.ExcludedMeasurementWindows=(row.ExcludedMeasurementWindows or 0)+1 end
    end
    local result = {
        Id = record.Id, ProfileId = record.ProfileId, Outcome = outcome,
        Resolution=resolution,MeasurementEligible=eligible==true,
        FollowupMode=record.FollowupMode,FollowupOptions=record.FollowupOptions,
        FollowupComplete=record.FollowupComplete==true,
        Interrupted = interrupted or "", HealthLoss = record.HealthLoss,
        NativeCancelled = record.NativeCancelled == true,
        Overlapping = record.Overlapping, Evidence = record.Evidence,
        Acknowledged = record.Acknowledged, MotionVerified = record.MotionVerified,
        EnvelopeComplete = record.EnvelopeComplete, TerrainChecked = record.TerrainChecked,
        Confidence = record.Confidence, ContactIn = record.ContactIn,
        Direction = record.Direction, PeakTravel = record.PeakTravel,
        PeakSpeed = record.PeakSpeed, At = now, Duration = math.max(0, now - record.StartedAt),
    }
    local head = self.DodgeAuditHead % 64 + 1
    self.DodgeAudit[head] = result
    self.DodgeAuditHead = head
    self.DodgeAuditCount = math.min(64, self.DodgeAuditCount + 1)
    self.LastDodgeOutcome = outcome
    pushReplay("dodge_outcome", now, {
        AuditId = record.Id, Outcome = outcome, HealthLoss = record.HealthLoss,
        Overlapping = record.Overlapping, Acknowledged = record.Acknowledged,
        Verified = record.MotionVerified, Interrupted = interrupted or "",
    })
end

function State:BeginDodgeAudit(threat, character, root, now, direction, plan)
    self:BindAuditHealth(character)
    if #self.PendingDodgeAudits >= 8 then
        self:FinishDodgeAudit(table.remove(self.PendingDodgeAudits, 1), now, "Capacity")
    end
    local row = self:AuditProfile(threat)
    if row then row.Requests += 1 end
    self.DodgeAuditSerial += 1
    local record = {
        Id = self.DodgeAuditSerial,
        ProfileId = row and row.Id or "Unindexed", Character = character,
        Root = root, StartPosition = root.Position, StartedAt = now,
        EndsAt = now + math.clamp((threat.ContactIn or 0) + 0.65, 0.65, 1.8),
        LastSampleAt = now, HealthLoss = 0, PeakTravel = 0, PeakSpeed = 0,
        Overlapping = #self.PendingDodgeAudits > 0,
        Evidence = self:EvidenceTier(threat), Direction = direction,
        Acknowledged = false, MotionVerified = false,
        EnvelopeComplete = plan and plan.EnvelopeComplete == true or false,
        TerrainChecked = true,
        FollowupMode=plan and plan.Followup and (plan.Followup.Complete and plan.Followup.Mode or "Budget deferred") or "Not evaluated",
        FollowupComplete=plan and plan.Followup and plan.Followup.Complete==true or false,
        FollowupOptions=plan and plan.Followup and plan.Followup.Complete and plan.Followup.Options or 0,
        Confidence = plan and plan.Confidence or threat.Confidence or 0,
        ContactIn = threat.ContactIn or -1,
    }
    for _, previous in ipairs(self.PendingDodgeAudits) do previous.Overlapping = true end
    self.PendingDodgeAudits[#self.PendingDodgeAudits + 1] = record
    return record
end

function State:AcknowledgeDodgeAudit(attempt, motionVerified)
    local record = attempt.Audit
    if not record or record.Finished then return end
    local row = self.AttackAudit[record.ProfileId]
    if not record.Acknowledged and row then row.Acknowledged += 1 end
    if motionVerified and not record.MotionVerified and row then row.MotionVerified += 1 end
    record.Acknowledged = true
    record.MotionVerified = motionVerified == true or record.MotionVerified
end

function State:SampleDodgeAudits(now, character)
    for index = #self.PendingDodgeAudits, 1, -1 do
        local record = self.PendingDodgeAudits[index]
        if record.Character ~= character or not record.Root.Parent then
            self:FinishDodgeAudit(record, now, "Character changed")
            table.remove(self.PendingDodgeAudits, index)
        else
            if now - record.LastSampleAt > 0.1 then record.ObservationGap = true end
            record.LastSampleAt = now
            local offset = record.Root.Position - record.StartPosition
            record.PeakTravel = math.max(record.PeakTravel, Vector3.new(offset.X, 0, offset.Z).Magnitude)
            local velocity = record.Root.AssemblyLinearVelocity
            record.PeakSpeed = math.max(record.PeakSpeed, Vector3.new(velocity.X, 0, velocity.Z).Magnitude)
            if now >= record.EndsAt then
                self:FinishDodgeAudit(record, now)
                table.remove(self.PendingDodgeAudits, index)
            end
        end
    end
end

function State:StopDodgeAudits(reason)
    local now = os.clock()
    for _, record in ipairs(self.PendingDodgeAudits) do self:FinishDodgeAudit(record, now, reason) end
    table.clear(self.PendingDodgeAudits)
    disconnect(self.AuditHealthConnection)
    self.AuditHealthConnection = nil
    self.AuditHumanoid = nil
    disconnect(self.NativeCancellationConnection)
    self.NativeCancellationConnection = nil
    self.NativeCancellationCharacter = nil
    table.clear(self.TerrainResultCache)
end

function State:GetAuditSnapshot(limit)
    limit = math.clamp(math.floor(tonumber(limit) or 24), 1, 64)
    local profiles, outcomes, blocks = {}, {}, {}
    for _, row in pairs(self.AttackAudit) do
        local copy=table.clone(row)
        copy.HealthWindowInterval=self:HealthWindowInterval(row.MeasuredHealthLosses or 0,row.MeasuredWindows or 0)
        profiles[#profiles+1]=copy
    end
    table.sort(profiles, function(a,b)
        if a.Observed == b.Observed then return a.Id < b.Id end
        return a.Observed > b.Observed
    end)
    while #profiles > limit do table.remove(profiles) end
    local count = math.min(limit, self.DodgeAuditCount)
    local first = (self.DodgeAuditHead - count) % 64 + 1
    for index = 1, count do
        outcomes[index] = table.clone(self.DodgeAudit[(first + index - 2) % 64 + 1])
    end
    for _, row in pairs(self.AuditBlocks) do blocks[#blocks + 1] = table.clone(row) end
    table.sort(blocks, function(a,b)
        if a.Count == b.Count then return a.Reason < b.Reason end
        return a.Count > b.Count
    end)
    return {
        Version = self.Version, Profiles = profiles, Outcomes = outcomes,
        Blocks = blocks, RecentEvents = self:GetReplaySnapshot(math.min(limit, 24)),
        ProfileCount = self.AttackAuditCount, DroppedProfiles = self.AuditDroppedProfiles,
        DashDispatchMode = self.DashDispatchMode,
        NativeDashMode = self.NativeModel and self.NativeModel.Mode or "Not sampled",
        NativeBoostSource = self.NativeBoostSource,
        HitboxModuleEvidence = self.HitboxModuleEvidence,
        GroupThreatCount = self.LastGroupThreatCount,
        GroupSourceCount = self.LastGroupSourceCount,
        GroupCoverageComplete = self.LastGroupCoverageComplete,
        GroupStatus = self.LastGroupStatus,
        GroupIncompleteBlocks = self.GroupIncompleteBlocks,
        AdaptiveSamples=self.AdaptiveSamples,AdaptiveHits=self.AdaptiveHits,
        FollowupCompleted=self.FollowupCompleted,FollowupDeferred=self.FollowupDeferred,
        FollowupMode=self.LastFollowupMode,FollowupOptions=self.LastFollowupOptions,
        PlanningReserveUses = self.PlanningReserveUses,
        LocalRestCorrections = self.LocalRestCorrections,
        LastDecisionBlock = self.LastDecisionBlock and table.clone(self.LastDecisionBlock),
        LastGroundFailure = self.LastGroundFailure and table.clone(self.LastGroundFailure),
        MeasuredTimingLead=self.LastEmpiricalLead,
        TimingEvidence=self:TimingEvidence(os.clock()),
        EstimatorUpdates=self.EstimatorUpdates,EstimatorRapidUpdates=self.EstimatorRapidUpdates,
        ScoreMeaning="Heuristic route score; not a calibrated dodge success probability",
        PendingWindows = #self.PendingDodgeAudits, CacheHits = self.TerrainCacheHits,
        CacheMisses = self.TerrainCacheMisses,
        Note = "Health loss is correlated with a time window; attack attribution and server hitboxes are unverified unless separately evidenced.",
    }
end

function State:GetAuditJSON(limit)
    return game:GetService("HttpService"):JSONEncode(self:GetAuditSnapshot(limit))
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
    -- Live damage telemetry reached phases 0.496-0.542. Keep the early
    -- edge for genuinely fast contacts, but do not retire the threat before
    -- the server's late fork hitbox has finished.
    Name = "Fork Swing 1", Weapon = "Fork", ActiveStart = 0.10,
    ActiveEnd = 0.62, AnimationLength = 1,
    WeaponParts = { "Fork" }, TipAttachments = { "AT1", "AT2" },
    WeaponRadius = 0.18,
})
bindExact("86197206792061", PROFILE_FAST_MELEE, {
    Name = "Fork Swing 2", Weapon = "Fork", ActiveStart = 0.105,
    ActiveEnd = 0.62, AnimationLength = 1,
    WeaponParts = { "Fork" }, TipAttachments = { "AT1", "AT2" },
    WeaponRadius = 0.18,
})
bindExact("99157505926076", PROFILE_LUNGE, {
    Name = "Fork/Bottle Lunge", Weapon = "ForkBottle", ActiveStart = 0.145,
    ActiveEnd = 0.62, AnimationLength = 0.9833,
    WeaponParts = { "Fork", "shattered", "WeaponBottle" },
    TipAttachments = { "AT1", "AT2" }, WeaponRadius = 0.34,
})
-- Life Drain's User/Victim tracks start only after a target is captured.
-- Detect the two startup tracks instead, before the rush/grab reaches the
-- local character. Their measured VFX rush phases are 0.4167 and 0.383.
bindExact("109822392402606", PROFILE_LUNGE, {
    Name = "Vampire Life Drain Startup", Weapon = "Vampire",
    ActiveStart = 0.30, ActiveEnd = 0.95, AnimationLength = 1.6667,
    Range = 22, FarReach = 19, Radius = 2.5, Arc = math.rad(55),
    Facing = 0, MobilitySpeed = 85, TravelHitbox = true,
})
bindExact("82579449181823", PROFILE_LUNGE, {
    Name = "Weak Vampire Life Drain Startup", Weapon = "Vampire",
    ActiveStart = 0.275, ActiveEnd = 0.90, AnimationLength = 1.5,
    Range = 22, FarReach = 19, Radius = 2.5, Arc = math.rad(55),
    Facing = 0, MobilitySpeed = 85, TravelHitbox = true,
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
    Name = "Fight Back Punch 1", Weapon = "Fists", ActiveStart = 0.075,
    ActiveEnd = 0.64, AnimationLength = 1.1017,
    Range = 14, NearReach = 0.5, FarReach = 10.5, Radius = 2.2,
    Arc = math.rad(82), Facing = 0.05, TravelHitbox = true,
    ComboFamily = "FightBack",
    ComboTail = { { Offset = 0.72, Reach = 19 }, { Offset = 1.55, Reach = 25 } },
})
bindExact("135690448001690", PROFILE_FAST_MELEE, {
    Name = "Fight Back Punch 2", Weapon = "Fists", ActiveStart = 0.075,
    ActiveEnd = 0.66, AnimationLength = 1.1017,
    Range = 14, NearReach = 0.5, FarReach = 10.5, Radius = 2.2,
    Arc = math.rad(82), Facing = 0.05, TravelHitbox = true,
    ComboFamily = "FightBack",
    ComboTail = { { Offset = 0.72, Reach = 20 }, { Offset = 1.55, Reach = 25 } },
})
bindExact("103355259844069", PROFILE_FAST_MELEE, {
    Name = "Fight Back Punch 3", Weapon = "Fists", ActiveStart = 0.06,
    ActiveEnd = 0.52, AnimationLength = 0.8,
    Range = 20, NearReach = 0.5, FarReach = 15, Radius = 2.65,
    Arc = math.rad(72), Facing = 0.1, TravelHitbox = true,
    ComboFamily = "FightBack",
    ComboTail = { { Offset = 0.72, Reach = 25 } },
})
bindExact("125906547773381", PROFILE_FAST_MELEE, {
    Name = "Fight Back Counter", Weapon = "Fists", ActiveStart = 0.08,
    ActiveEnd = 0.76, AnimationLength = 1.2167,
    Range = 26, NearReach = 0.5, FarReach = 20.5, Radius = 3,
    Arc = math.rad(60), Facing = 0.16, TravelHitbox = true,
    ComboFamily = "FightBack",
    ComboTail = { { Offset = 0.72, Reach = 20 } },
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

local function bindThrow(
    id,
    name,
    weapon,
    releaseAt,
    animationLength,
    speed,
    radius,
    canonicalSignature
)
    return bindExact(id, PROFILE_THROW, {
        Name = name,
        Weapon = weapon,
        ActiveStart = releaseAt,
        ActiveEnd = releaseAt + 0.12,
        ReleaseAt = releaseAt,
        AnimationLength = animationLength,
        ProjectileSpeed = speed,
        ProjectileRadius = radius,
        ProjectileSignature = canonicalSignature or string.lower(weapon),
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
bindThrow("76323709902827", "Magician Card Throw", "CardModel", 0.35, 1.6667, 105, 0.7, "card")
bindThrow("131235569946744", "Rabbit Hex Cast", "RabbitHexBolt", 0.3, 1.5, 92, 0.65, "rabbithex")
bindThrow("70775136168849", "Pumpkin Throw", "Pumpkin", 0.694, 3.17, 88, 1.05, "pumpkin")
bindThrow("114769224376981", "Coal Throw", "Coal", 0.25, 1.3, 105, 0.7, "coal")
bindThrow("122821907040284", "Present Throw", "Present", 0.3, 1.5, 78, 1.05, "present")
bindThrow("128733894961951", "Ice Shuriken", "IceShuriken", 0.25, 2.8, 125, 1.35, "shuriken")

-- Confirmed damaging ability starts from the live ability animation tree.
-- Post-hit victim/beatdown tracks are intentionally not bound here.
bindExact("115925088060952", PROFILE_HEAVY, {
    Name = "Ballistic Shield Bash", Weapon = "RiotShield",
    ActiveStart = 0.12, ActiveEnd = 0.55, AnimationLength = 0.9833,
    Range = 14, FarReach = 11, Radius = 2.35,
    WeaponParts = { "RiotShield" }, WeaponRadius = 0.7,
})
bindExact("124127720565083", PROFILE_LUNGE, {
    Name = "Human Shield Grab Attempt", Weapon = "Body",
    ActiveStart = 0.18, ActiveEnd = 0.78, AnimationLength = 1.55,
    Range = 20, FarReach = 16, Radius = 2.4, TravelHitbox = true,
})
bindExact("132207921464999", PROFILE_LUNGE, {
    Name = "Rumor Grab Attempt", Weapon = "Body",
    ActiveStart = 0.12, ActiveEnd = 0.58, Range = 19,
    FarReach = 15, Radius = 2.5, TravelHitbox = true,
})
bindExact("77595339119545", PROFILE_HEAVY, {
    Name = "SubZero Spear Attack", Weapon = "Spear",
    ActiveStart = 0.15, ActiveEnd = 0.75, AnimationLength = 1.3,
    Range = 27, FarReach = 23, Radius = 2.1,
    WeaponParts = { "Spear" },
})
bindExact("133847489167018", PROFILE_LUNGE, {
    Name = "SubZero Hammer Grab Start", Weapon = "Hammer",
    ActiveStart = 0.16, ActiveEnd = 0.62, Range = 21,
    FarReach = 17, Radius = 2.7, TravelHitbox = true,
    WeaponParts = { "Hammer", "IceHammer" },
})
bindExact("123370871049938", PROFILE_FAST_MELEE, {
    Name = "SubZero Tanto Attack", Weapon = "Tanto",
    ActiveStart = 0.05, ActiveEnd = 0.44, AnimationLength = 0.4667,
    Range = 13, FarReach = 10, Radius = 1.9,
    WeaponParts = { "LeftTanto" },
})
bindExact("78650777657300", PROFILE_HEAVY, {
    Name = "Virtuoso Guitar Slam", Weapon = "Guitar",
    ActiveStart = 0.18, ActiveEnd = 0.8, AnimationLength = 1.15, Range = 22,
    FarReach = 18, Radius = 3, WeaponParts = { "Guitar" },
})
bindExact("85423751361183", PROFILE_AREA, {
    Name = "Tempest Shield Burst", Weapon = "Shield",
    ActiveStart = 0.08, ActiveEnd = 0.55, AnimationLength = 0.8,
    Range = 24, Radius = 24,
})
bindExact("119784367902126", PROFILE_AREA, {
    Name = "Vampire Blood Burst Start", Weapon = "Vampire",
    ActiveStart = 0.11, ActiveEnd = 0.8, AnimationLength = 3.3333,
    Range = 23, Radius = 23,
})

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
bindExact("81533666958052", PROFILE_LUNGE, {
    Name = "Hercules Whiff", Weapon = "Body", ActiveStart = 0.12,
    ActiveEnd = 0.58, AnimationLength = 1.1,
    TravelHitbox = true, MobilitySpeed = 110,
})
bindExact("93373403484012", PROFILE_LUNGE, {
    Name = "Umbrella Lunge", Weapon = "Umbrella", ActiveStart = 0.31,
    ActiveEnd = 0.78, AnimationLength = 2.5833,
    WeaponParts = { "Plane.010" }, TipAttachments = { "P1", "P" },
    WeaponRadius = 0.55,
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
    card = { Name = "Card", Radius = 0.7, TTL = 4, Canonical = "card" },
    cardmodel = { Name = "Card", Radius = 0.7, TTL = 4, Canonical = "card" },
    coal = { Name = "Coal", Radius = 0.7, TTL = 4, Canonical = "coal" },
    iceshuriken = { Name = "Ice Shuriken", Radius = 1.35, TTL = 4, Canonical = "shuriken" },
    shuriken = { Name = "Ice Shuriken", Radius = 1.35, TTL = 4, Canonical = "shuriken" },
    rabbithex = { Name = "Rabbit Hex Bolt", Radius = 0.65, TTL = 5, Canonical = "rabbithex" },
    rabbithexbolt = { Name = "Rabbit Hex Bolt", Radius = 0.65, TTL = 5, Canonical = "rabbithex" },
    hexbolt = { Name = "Rabbit Hex Bolt", Radius = 0.65, TTL = 5, Canonical = "rabbithex" },
    inkpole = { Name = "Pole", Radius = 0.45, TTL = 4, Canonical = "pole" },
    pumpkin = { Name = "Pumpkin", Radius = 1.05, TTL = 5 },
    present = { Name = "Present", Radius = 1.05, TTL = 5 },
}

local WEAPON_PART_NAMES = {
    fork = true, knife = true, shattered = true, weaponbottle = true,
    inkpole = true, pole = true, rock = true, default = true,
    metalbat = true, bat = true, umbrella = true,
    shield = true, ballisticshield = true, riotshield = true,
    spear = true, icespear = true, hammer = true, icehammer = true,
    tanto = true, lefttanto = true, guitar = true, ["plane.010"] = true,
    cardmodel = true, card1 = true, handlecard = true, coal = true,
    iceshuriken = true, leftshuriken = true, rightshuriken = true,
    rabbithexbolt = true, pumpkin = true, present = true,
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

local function walkDescendantsBounded(root, limit, callback)
    if not root or not callback then
        return 0
    end
    limit = math.max(1, math.floor(tonumber(limit) or 1))
    local queue = table.create(math.min(limit, 64))
    for _, child in ipairs(root:GetChildren()) do
        if #queue >= limit then
            break
        end
        queue[#queue + 1] = child
    end
    local cursor = 1
    while cursor <= #queue and cursor <= limit do
        local object = queue[cursor]
        cursor += 1
        if callback(object) == false then
            break
        end
        if #queue < limit then
            for _, child in ipairs(object:GetChildren()) do
                if #queue >= limit then
                    break
                end
                queue[#queue + 1] = child
            end
        end
    end
    local visited = math.min(cursor - 1, limit)
    table.clear(queue)
    return visited
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
    walkDescendantsBounded(watcher.Character, 160, function(object)
        cacheWeaponPart(watcher, object)
    end)
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
                    -- Preserve the cardinal direction so the short replication
                    -- bridge can validate forward/side/back motion in world
                    -- space before the velocity sample catches up.
                    dashIds[id] = animation.Name
                end
            end
        end
    end

    local function indexFolder(path, profileForName)
        local folder = findPath(animations, path)
        if not folder or hasGunToken(table.concat(path, "/")) then
            return
        end
        -- These are explicitly selected attack folders, but traversal remains
        -- bounded so a malformed/late asset hierarchy cannot hitch the client.
        walkDescendantsBounded(folder, 192, function(object)
            if object:IsA("Animation") then
                local profile = not hasGunToken(object.Name)
                    and profileForName(object.Name) or nil
                if profile then
                    add(object, profile)
                end
            end
        end)
    end

    indexFolder({ "Abilities", "Fists" }, function(name)
        if name:find("Lunge") then
            return PROFILE_LUNGE
        elseif name:find("Swing") then
            return PROFILE_FAST_MELEE
        end
    end)
    indexFolder({ "Abilities", "Knife" }, function(name)
        if name:find("Victim") or name:find("BackStabChar")
            or name:find("BackstabChar") then
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
    addExact({ "Abilities", "Hercules", "HerculesWhiff" }, PROFILE_LUNGE)
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
    "tackle", "slam", "strike", "throw",
}
local PASSIVE_NAME_TOKENS = {
    "victim", "equip", "pickup", "receive", "give", "idle",
    "walk", "run", "jump", "fall", "reload", "charge",
    "beatdown", "qte", "blockhit", "captured", "finisher",
    "cinematic", "grabloop", "grabbed", "won", "lost",
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

function State:ResetMotionEstimate(motion)
    motion.VelocityVariance = Vector3.new(36,36,36)
    motion.ChangeEvidence = 0
    motion.AbruptChanges = 0
end

do
local function estimateAxis(prior,target,assembly,variance,dt,jitter,reset)
    local residual=target-prior
    local p=math.clamp(variance+dt*(16+math.min(500,residual*residual*.2)),.05,1600)
    local disagreement=target-assembly
    local noise=4+disagreement*disagreement*.25+jitter
    local gain=p/(p+noise)
    if reset then gain=math.max(gain,.9) else
        local bound=5*math.sqrt(p+noise)+12
        residual=math.clamp(residual,-bound,bound)
    end
    return prior+gain*residual,math.clamp((1-gain)*p,.05,1600)
end
function State:EstimateMotionVelocity(motion, target, assembly, dt)
    local prior = motion.Velocity
    local variance = motion.VelocityVariance or Vector3.new(36,36,36)
    local change = (target-prior).Magnitude
    local abrupt = change > math.max(18, prior.Magnitude*.45)
    local agrees = (target-assembly).Magnitude <= math.max(12,target.Magnitude*.35)
    motion.ChangeEvidence = abrupt and math.min(3,(motion.ChangeEvidence or 0)+1) or 0
    local reset = abrupt and (agrees or motion.ChangeEvidence >= 2)
    self.EstimatorUpdates+=1
    if reset then
        motion.AbruptChanges=(motion.AbruptChanges or 0)+1
        self.EstimatorRapidUpdates+=1
    end
    local jitter=math.min(100,(motion.PositionJitter or .15)^2/math.max(dt*dt,.000001)*.05)
    local x,px=estimateAxis(prior.X,target.X,assembly.X,variance.X,dt,jitter,reset)
    local y,py=estimateAxis(prior.Y,target.Y,assembly.Y,variance.Y,dt,jitter,reset)
    local z,pz=estimateAxis(prior.Z,target.Z,assembly.Z,variance.Z,dt,jitter,reset)
    motion.VelocityVariance=Vector3.new(px,py,pz)
    return Vector3.new(x,y,z)
end
end

function State:RecordTimingSample(kind,value,now)
    if type(value)~="number" or value~=value or value<0 or value==math.huge then return false end
    local maximum = kind=="Ping" and .5 or .25
    local buffer=self.TimingSamples[kind]
    if not buffer then buffer={Values={},Times={},Head=0,Count=0}; self.TimingSamples[kind]=buffer end
    buffer.Head=buffer.Head%64+1
    buffer.Values[buffer.Head]=math.min(value,maximum)
    buffer.Times[buffer.Head]=now
    buffer.Count=math.min(64,buffer.Count+1)
    return true
end

function State:TimingQuantile(kind,q,now,minimum)
    local buffer=self.TimingSamples[kind]
    if not buffer then return nil,0 end
    if buffer.CacheQ==q and now<(buffer.CacheUntil or 0) then
        if buffer.CacheCount >= minimum then return buffer.CacheValue,buffer.CacheCount end
        return nil,buffer.CacheCount
    end
    local values={}
    for index=1,buffer.Count do
        if now-buffer.Times[index]<=20 and now>=buffer.Times[index] then values[#values+1]=buffer.Values[index] end
    end
    table.sort(values)
    local value=#values>0 and values[math.clamp(math.ceil(q*#values),1,#values)] or nil
    buffer.CacheQ,buffer.CacheUntil,buffer.CacheCount,buffer.CacheValue=q,now+.1,#values,value
    if #values<minimum then return nil,#values end
    return value,#values
end

function State:TimingEvidence(now)
    local result={}
    for kind in pairs(self.TimingSamples) do
        local q=kind=="Frame" and .95 or .9
        local minimum=kind=="Frame" and 12 or 8
        local value,count=self:TimingQuantile(kind,q,now,minimum)
        result[kind]={UsableSamples=count,RequiredSamples=minimum,Quantile=q,Seconds=value}
    end
    return result
end

function State:OutcomeResolution(record,interrupted)
    if interrupted then return "Observation interrupted" end
    if record.NativeCancelled then return "Native dash interrupted" end
    if not record.Acknowledged then return "Controller unacknowledged" end
    if not record.MotionVerified then return "Movement unverified" end
    if record.ObservationGap then return "Observation gap" end
    if record.Overlapping then return "Overlapping attack windows" end
    if record.HealthLoss>0 then return "Health loss after verified movement" end
    return "No health loss after verified movement"
end

function State:HealthWindowInterval(losses,total)
    if total<=0 then return nil end
    local p=losses/total
    local z=1.96
    local denominator=1+z*z/total
    local center=(p+z*z/(2*total))/denominator
    local half=z*math.sqrt(p*(1-p)/total+z*z/(4*total*total))/denominator
    return {ObservedFraction=p,Lower=math.max(0,center-half),Upper=math.min(1,center+half),Samples=total,
        Meaning="Descriptive health-loss window interval; assumes comparable independent observations; not dodge success probability"}
end

function State:PreferFollowup(candidate,best)
    if not best or not candidate.Safe or not best.Safe
        or not candidate.Followup or not best.Followup
        or not candidate.Followup.Complete or not best.Followup.Complete
        or math.abs(candidate.WorstClearance-best.WorstClearance)>1.5 then return nil end
    if candidate.Followup.Options~=best.Followup.Options then return candidate.Followup.Options>best.Followup.Options end
    return nil
end

-- Only locally owned motion has immediate position, input and velocity evidence.
-- Remote replication pauses must never be mistaken for a confirmed stop.
function State:ObserveLocalRest(motion, delta, assembly, dt, now, eligible)
    local horizontalDelta = Vector3.new(delta.X, 0, delta.Z).Magnitude
    local horizontalSpeed = Vector3.new(assembly.X, 0, assembly.Z).Magnitude
    if not eligible or horizontalDelta > math.max(0.002, dt * 0.2)
        or horizontalSpeed > 0.75 then
        motion.RestSince = nil
        motion.RestSamples = 0
        motion.ObservedRest = false
        return false
    end
    motion.RestSince = motion.RestSince or now - math.min(dt, 0.02)
    motion.RestSamples = (motion.RestSamples or 0) + 1
    if motion.RestSamples < 2 or now - motion.RestSince < 0.016 then return false end
    if Vector3.new(motion.Velocity.X, 0, motion.Velocity.Z).Magnitude > 0.25 then
        self.LocalRestCorrections += 1
    end
    motion.Velocity = Vector3.new(0, motion.Velocity.Y, 0)
    motion.ShortVelocity = Vector3.new(0, motion.ShortVelocity.Y, 0)
    motion.Acceleration = Vector3.new(0, motion.Acceleration.Y, 0)
    motion.Jerk = Vector3.new(0, motion.Jerk.Y, 0)
    motion.ObservedRest = true
    return true
end

function State:ActionPlanningDeadline(started, dynamicBudget)
    local duration = math.clamp(dynamicBudget, 0.0018, MPC_WORK_BUDGET)
    local deadline = started + duration
    if self.FrameBudgetActive and (self.FrameDeadline or 0) > 0 then
        local shared = math.min(deadline, self.FrameDeadline)
        local reserve = math.clamp(self.MinimumActionPlanningBudget, 0, duration)
        deadline = math.max(shared, started + reserve)
        if deadline > shared then self.PlanningReserveUses += 1 end
    end
    return deadline
end

function State:RecordDecisionBlock(threat, now)
    local reason = self.LastBlockReason or "Unknown"
    local previous = self.LastDecisionBlock
    if previous and previous.Reason == reason and now - previous.At < 0.25 then return end
    local motion = self.LocalMotion
    self.LastDecisionBlock = {
        At = now, Reason = reason,
        Threat = threat and threat.Profile and threat.Profile.Name or "Unknown",
        ContactIn = threat and threat.ContactIn or -1,
        ObservedRest = motion and motion.ObservedRest == true or false,
        EnvelopeComplete = self.LastEnvelopeComplete == true,
        SolverReason = self.LastMpcBudgetReason,
    }
    if reason == "Group evaluation incomplete" or reason == "Learned threat confidence"
        or reason == "Threat changed before act" then
        self:RecordAuditBlock(threat, reason, now)
    end
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
    State:ResetMotionEstimate(motion)
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
        motion.RestSince = nil
        motion.RestSamples = 0
        motion.ObservedRest = false
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
        State:ResetMotionEstimate(motion)
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
    local velocity = State.EnableMotionEstimator
        and State:EstimateMotionVelocity(motion,targetVelocity,assemblyVelocity,deltaTime)
        or previousVelocity:Lerp(targetVelocity,velocityAlpha)
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
    local localCharacter = LocalPlayer.Character
    local owned = localCharacter ~= nil and root.Parent == localCharacter
    local humanoid = owned and localCharacter:FindFirstChildOfClass("Humanoid")
    State:ObserveLocalRest(motion, positionDelta, assemblyVelocity, deltaTime, now,
        owned and humanoid ~= nil and humanoid.MoveDirection.Magnitude < 0.05)
    State:PushMotionHistory(motion, now, position, motion.Velocity)
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

-- Derived from supplied Main, MoreFunctionsClient.Roll and SharedFunctions.
-- These are requested velocity curves, not a guarantee of physical travel.
function State:BuildNativeDashModel(mode, swing, nerfed, boost, chargeSeconds)
    swing = tonumber(swing) or 1
    if swing ~= swing or swing <= 0 or swing == math.huge then swing = 1 end
    local charge = chargeSeconds and (math.clamp(chargeSeconds, 0, 0.85) / 0.85 * 0.590625 + 1) or 1
    local model = { Mode = mode, Duration = 0.5, InitialDuration = 0.1,
        Swing = swing, AbsoluteVelocity = true, ChargeScale = charge }
    if mode == "Wally" then
        model.Duration = 0.05
        model.InitialDuration = 0.05
        model.InitialSpeed = 900 * swing
        model.BlockedSpeed = 90 * swing
        model.ProbeLength = 30 * swing
        model.TailSpeed = 0
    elseif mode == "Phantom" then
        local tier = math.clamp(math.floor((tonumber(boost) or 0) / 1.5 + 0.5), 0, 5)
        model.Duration = 0.05
        model.InitialDuration = 0.05
        model.InitialSpeed = 7 * 27 * (tier * 0.03 + 1) * swing * charge
        model.BlockedSpeed = 21 * swing * charge
        model.ProbeLength = 7 * swing
        model.TailSpeed = 0
    else
        local scale = (nerfed and 0.65 or 1) * swing * charge
        model.InitialSpeed = 113.75 * scale
        model.TailSpeed = 60 * scale
        if mode == "UltraInstinct" then
            model.InitialSpeed *= 2.5
            model.TailSpeed *= 2
            model.InitialDuration = 0.04
        end
    end
    return model
end

function State:NativeDashDistanceFromModel(model, timeAhead, blocked)
    local time = math.clamp(tonumber(timeAhead) or 0, 0, model.Duration)
    if model.Duration <= 0.05 then
        return (blocked and model.BlockedSpeed or model.InitialSpeed) * time
    end
    local first = math.min(time, model.InitialDuration) * model.InitialSpeed
    if time <= model.InitialDuration then return first end
    local tailTime = model.Duration - model.InitialDuration
    local t = (time - model.InitialDuration) / tailTime
    -- Integral of cubic Bezier velocity with control points {1, .8, .2, 0}.
    local integral = t - 0.3*t*t - 0.4*t*t*t + 0.2*t*t*t*t
    return first + model.TailSpeed * tailTime * integral
end

function State:InitializeNativeReaders()
    if self.NativeSharedFunctions then return end
    local modules = ReplicatedStorage:FindFirstChild("Modules")
    local sharedModule = modules and modules:FindFirstChild("SharedFunctions")
    if sharedModule and sharedModule:IsA("ModuleScript") then
        local ok, value = pcall(require, sharedModule)
        if ok and type(value) == "table" then self.NativeSharedFunctions = value end
    end
end

function State:ReadNativeSprintBoost()
    local boosts = LocalPlayer:FindFirstChild("Boosts")
    local value = boosts and boosts:FindFirstChild("Faster Sprint")
    local raw = value and tonumber(value.Value) or 0
    local maximum = workspace:GetAttribute("MaxSpeedBoosts")
    local now = os.clock()
    if self.NativeBoostRaw == raw and self.NativeBoostMaximum == maximum
        and now < (self.NativeBoostExpiresAt or 0) then return self.NativeBoostValue end
    local resolved = raw
    local reader = self.NativeSharedFunctions and self.NativeSharedFunctions.GetBoosts
    self.NativeBoostSource = "Raw boost fallback"
    if type(reader) == "function" then
        local ok, result = pcall(reader, LocalPlayer, "Faster Sprint")
        if ok and type(result) == "number" and result == result and math.abs(result) < math.huge then
            resolved = result
            self.NativeBoostSource = "SharedFunctions.GetBoosts"
        end
    end
    self.NativeBoostRaw, self.NativeBoostMaximum = raw, maximum
    self.NativeBoostExpiresAt, self.NativeBoostValue = now + 0.02, resolved
    return resolved
end

function State:GetNativeDashModel(character)
    local swingValue = character and character:FindFirstChild("SwingSpeed")
    local swing = swingValue and tonumber(swingValue.Value) or 1
    local override = character and character:FindFirstChild("PowerOverwrite")
    -- Roll uses this raw power selection, separately from Main's unlock rules.
    local power = override and override.Value or LocalPlayer:GetAttribute("_EquippedPower")
    if getValue("PowersDisabled", false) then power = nil end
    local wally = character and tonumber(character:GetAttribute("WallyWestRun")) or 0
    local mode = wally >= 50 and "Wally"
        or power == "PHANTOM STEP" and "Phantom"
        or power == "ULTRA INSTINCT" and "UltraInstinct" or "Normal"
    local boost = mode == "Phantom" and self:ReadNativeSprintBoost() or 0
    local nerfed = getValue("NerfedMovement", false) == true
    local signature = string.format("%s|%.6f|%s|%.6f|uncharged", mode, swing,
        nerfed and "Nerfed" or "Full", boost)
    if self.NativeModelCharacter ~= character or self.NativeModelSignature ~= signature then
        self.NativeModel = self:BuildNativeDashModel(mode, swing, nerfed, boost)
        self.NativeModel.Signature = signature
        self.NativeModelCharacter, self.NativeModelSignature = character, signature
    end
    return self.NativeModel
end

function State:NativeDashStunReason(character)
    if character:FindFirstChild("Dead") then return "Dead marker" end
    for _, child in ipairs(character:GetChildren()) do
        if child.Name == "Stun" and not (child:GetAttribute("GettingShot")
            or child:GetAttribute("CanFireGun") or child:GetAttribute("FakeStun")
            or child:GetAttribute("CanDash")) then
            return "Stun marker"
        end
    end
    return nil
end

function State:NativeDashCancelMarker(child)
    -- Roll's cancellation predicate differs from its permission-to-start gate.
    return child.Name == "Dead" or child.Name == "Stun" and not (
        child:GetAttribute("InStartup") or child:GetAttribute("IgnoreDashCancel")
        or child:GetAttribute("CanDash"))
end

function State:BindNativeDashCancellation(character)
    if self.NativeCancellationCharacter == character and self.NativeCancellationConnection then return end
    disconnect(self.NativeCancellationConnection)
    self.NativeCancellationCharacter = character
    self.NativeCancellationConnection = character.ChildAdded:Connect(function(child)
        if not self.Enabled or not self:NativeDashCancelMarker(child) then return end
        local affected = false
        for _, record in ipairs(self.DashTelemetry) do
            if record.Character == character then record.Rejected = true; affected = true end
        end
        for _, record in ipairs(self.PendingDodgeAudits) do
            if record.Character == character and not record.Finished then
                record.NativeCancelled = true
                record.ObservationGap = true
                affected = true
            end
        end
        if affected then pushReplay("native_dash_interrupted", os.clock(), { Reason = child.Name }) end
    end)
end

function State:NativeNormalCooldown(character, now)
    local controller = self:ResolveDashControllerState(character)
    if controller then
        if controller.DidEffect or controller.DashZoomIn then
            return false, "Manual dash charge active", 0, "Controller"
        end
        if controller.DashCD then return false, "Native DashCD", 0, "Controller" end
        return true, "Ready", 0, "Controller"
    end
    -- Without the native table, preserve a conservative observable fallback.
    local cooldown = getNativeCooldown(character)
    local recent = character:GetAttribute("RecentDash")
    local remaining = cooldown - (now - self.LastAcceptedAt)
    if type(recent) == "number" then remaining = math.max(remaining, cooldown - (tick() - recent)) end
    if remaining > 0 then return false, "Cooldown fallback", remaining, "Fallback" end
    return true, "Ready", 0, "Fallback"
end

function State:NativeDashAcknowledgement(attempt, controller, attributeChanged, newMover, stackAcknowledged)
    if stackAcknowledged then return true, "Stack" end
    if controller and attempt.BeforeNativeControllerPresent and not attempt.WasPhantomStep
        and not attempt.BeforeNativeDashCD and controller.DashCD == true then
        return true, "ControllerDashCD"
    end
    if attributeChanged and newMover then return true, "DashMover" end
    return false, "Unverified"
end

function State:NativeBurstPathClear(character, startPosition, path, model)
    if model.Duration > 0.05 or path.Magnitude < 0.001 then return true end
    local parameters = self:BuildTerrainParameters(character)
    local filter = parameters.FilterDescendantsInstances
    for _, root in ipairs(self.EventMapRoots) do
        if root and root.Parent == workspace then filter[#filter + 1] = root end
    end
    parameters.FilterDescendantsInstances = filter
    parameters.CollisionGroup = "Default"
    parameters.IgnoreWater = true
    -- Native Roll slows a burst when its forward probe sees a collidable
    -- obstacle. Check the union of probes along the entire planned route.
    -- RespectCanCollide makes this conservative when non-solid visuals hide
    -- a wall from the native first-hit query.
    parameters.RespectCanCollide = true
    local hit = workspace:Raycast(startPosition,
        path + path.Unit * (model.ProbeLength or 0), parameters)
    return hit == nil, hit and hit.Instance
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
    local model = self:GetNativeDashModel(character)
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local ground = humanoid and humanoid.FloorMaterial ~= Enum.Material.Air and "Ground" or "Air"
    return model.Signature .. "|" .. ground
end

function State:CurrentDashCalibrationKey(character, phantom)
    -- Re-read the cheap modifier signature so power/nerf changes are immediate.
    return self:DashCalibrationKey(character, phantom)
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
    self:BindNativeDashCancellation(character)
    -- A later dash contaminates the remainder of an earlier trajectory.
    for _, previous in ipairs(State.DashTelemetry) do
        previous.Rejected = true
    end
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
        StartHealth = (character:FindFirstChildOfClass("Humanoid") or {}).Health,
        -- Every Roll branch writes an absolute target velocity. Subtracting
        -- continued pre-dash walking would inflate reverse-direction travel
        -- and shrink forward-direction travel in the learned distance curve.
        BaselineVelocity = ZERO, -- Roll sets an absolute target velocity in every mode.
        Phantom = self:GetNativeDashModel(character).Duration <= 0.05,
        NativeMode = self:GetNativeDashModel(character).Mode,
        InitialCameraLook = workspace.CurrentCamera and horizontalUnit(workspace.CurrentCamera.CFrame.LookVector),
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
    -- Phantom and Wally use scheduled 50 ms bursts. Later samples contain
    -- restored walking, so they must not replace the burst controller model.
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
            local camera = workspace.CurrentCamera
            if record.InitialCameraLook and camera
                and record.InitialCameraLook:Dot(horizontalUnit(camera.CFrame.LookVector)) < math.cos(math.rad(10))
                or record.Key ~= self:CurrentDashCalibrationKey(record.Character, record.Phantom) then
                record.Rejected = true
            end
            local humanoid = record.Character:FindFirstChildOfClass("Humanoid")
            if interval > self.MaximumDashTelemetryGap
                or humanoid and record.StartHealth and humanoid.Health < record.StartHealth then
                record.Rejected = true
            end
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
    State:RecordTimingSample("Frame",rawFrame,now)
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
            State:RecordTimingSample("Ping",ping,now)
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
    local ping=State.PingMean+2.5*State.PingDeviation
    local frame=math.max(State.FrameMean,State.DecayingWorstFrame)
    local startup=State.DashStartupMean+2.5*State.DashStartupDeviation
    if State.EnableEmpiricalTiming then
        local now=os.clock()
        ping=math.max(ping,State:TimingQuantile("Ping",.9,now,8) or 0)
        frame=math.max(frame,State:TimingQuantile("Frame",.95,now,12) or 0)
        local mode=State.NativeModel and State.NativeModel.Mode or "Normal"
        startup=math.max(startup,State:TimingQuantile("Startup:"..mode,.9,now,8) or 0)
    end
    State.LastEmpiricalLead=ping+frame+startup
    return math.clamp(
        ping+frame+startup
            + math.min(State.ServerClockDeviation, 0.02)
            + weaponJitter
            + 0.01
            + State.ReactionLeadMilliseconds / 1000,
        0.055,
        0.34
    )
end

-- Every action path uses this clock. Prediction lead affects collision
-- estimates, while the reaction wait starts only after confirmed contact.
function State:ReactionReadyAt(threat)
    local confirmedAt = threat and threat.FirstConfirmedAt
    local delayMilliseconds = self.FixedReactionMilliseconds
    if not finiteNumber(confirmedAt) or not finiteNumber(delayMilliseconds)
        or delayMilliseconds < 0 then
        return nil
    end
    return confirmedAt + delayMilliseconds / 1000
end

function State:ReactionReady(threat, now)
    local readyAt = self:ReactionReadyAt(threat)
    return readyAt ~= nil and now >= readyAt
end

function State:ClearReactionConfirmation(threat)
    threat.CountedPrediction = false
    threat.FirstConfirmedAt = nil
    threat.LastConfirmedAt = nil
end

-- A physical projectile and its attack animation represent the same threat.
-- Keep the earliest still-valid confirmation when their records are fused.
function State:MergeReactionConfirmation(target, source, now)
    if not finiteNumber(target.FirstConfirmedAt)
        or not finiteNumber(target.LastConfirmedAt)
        or now - target.LastConfirmedAt > math.max(0.06, 2 * self.FrameMean) then
        self:ClearReactionConfirmation(target)
    end
    if not source or not finiteNumber(source.FirstConfirmedAt)
        or not finiteNumber(source.LastConfirmedAt)
        or now - source.LastConfirmedAt > math.max(0.06, 2 * self.FrameMean) then
        return
    end
    if not finiteNumber(target.FirstConfirmedAt)
        or source.FirstConfirmedAt < target.FirstConfirmedAt then
        target.FirstConfirmedAt = source.FirstConfirmedAt
    end
    target.LastConfirmedAt = math.max(
        target.LastConfirmedAt or source.LastConfirmedAt,
        source.LastConfirmedAt
    )
    target.CountedPrediction = true
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

function State:BoundHeldWeaponCenter(currentCenter, predictedCenter, rootPosition, predictedRoot)
    -- Arm/weapon motion can rotate around its holder, but cannot launch a
    -- held weapon dozens of studs away because of a noisy velocity sample.
    local radius = (currentCenter - rootPosition).Magnitude + 1.5
    return predictedRoot + clampMagnitude(predictedCenter - predictedRoot, radius)
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
    ) - attackerMotion.Position
        + State:ProvisionalDashOffset(threat, attackerMotion, timeAhead)
        + (hypothesisOffset or ZERO)
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
    local predictedBase = sample.Base + rootDelta + baseResidual * residualScale
    local predictedTip = sample.Tip + rootDelta + tipResidual * residualScale
    local center = State:BoundHeldWeaponCenter(
        (sample.Base + sample.Tip) * 0.5,
        (predictedBase + predictedTip) * 0.5,
        attackerMotion.Position,
        attackerMotion.Position + rootDelta
    )
    local originalSegment = sample.Tip - sample.Base
    local half = unitOrFallback(predictedTip - predictedBase, originalSegment)
        * originalSegment.Magnitude * 0.5
    return center - half, center + half, sample.Radius
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
    ) - attackerMotion.Position
        + State:ProvisionalDashOffset(threat, attackerMotion, timeAhead)
        + (hypothesisOffset or ZERO)
    local rootVelocity = predictionVelocity(attackerMotion, threat.DashAttack)
    local decayTime = 0.065
    local residualScale = decayTime * (1 - math.exp(-timeAhead / decayTime))
    local center = sample.CFrame.Position + rootDelta
        + clampMagnitude(sample.CenterVelocity - rootVelocity, 800)
            * residualScale
    center = State:BoundHeldWeaponCenter(
        sample.CFrame.Position, center, attackerMotion.Position,
        attackerMotion.Position + rootDelta
    )
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
        threat.LastPlayingPhase = elapsed
        threat.StoppedPhase = nil
    elseif track and threat.StoppedPhase == nil then
        -- Freeze cancellation evidence before advancing the logical clock.
        -- Otherwise a stopped windup can age into a fictional active attack.
        threat.StoppedPhase = math.max(
            track.TimePosition or 0,
            threat.LastPlayingPhase or threat.LogicalElapsed or 0
        )
    end
    threat.PlaybackSpeed = speed
    threat.LogicalElapsed = elapsed
    threat.LastPhaseAt = now

    local profile = threat.Profile
    local effectiveStart, effectiveEnd, effectiveRelease = effectiveTiming(
        profile,
        threat.TimingKey
    )
    local hbSpec = State.GetHBProfile and State:GetHBProfile(threat)
    if hbSpec then
        effectiveStart, effectiveEnd = hbSpec.ActiveStart, hbSpec.ActiveEnd
    end
    local untilActive = (effectiveStart - elapsed) / speed
    local untilFinished = (effectiveEnd - elapsed) / speed
    return math.max(0, untilActive), math.max(0, untilFinished), elapsed,
        effectiveStart, effectiveEnd, effectiveRelease
end

function State:IsCancelledAttack(threat, activePhase)
    return threat.Track ~= nil and not threat.Track.IsPlaying
        and threat.StoppedPhase ~= nil
        and threat.StoppedPhase < activePhase - POST_ACTIVE_TOLERANCE
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
    if State.EnableMotionEstimator then
        local first=localMotion.VelocityVariance or ZERO
        local second=attackerMotion.VelocityVariance or ZERO
        local sigma=math.sqrt(math.max(first.X+second.X,first.Z+second.Z))
        uncertainty=math.max(uncertainty,.55+1.5*sigma*math.min(horizon,.35))
    end
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

-- Confirmed call-site profiles only. Never infer HB options from a weapon's
-- visible part, a visualizer message, or the shared module's defaults.
State.ConfirmedHBProfiles = {}

function State:RegisterHBProfile(animationId, spec)
    local id = normalizeAnimationId(animationId)
    if type(spec) == "table" and spec.Module == "Modules.Hitbox" then return false end
    if not id or type(spec) ~= "table" or spec.Confirmed ~= true
        or type(spec.Source) ~= "string" or #spec.Source == 0
        or not finiteVector(spec.HitboxSize)
        or math.min(spec.HitboxSize.X, spec.HitboxSize.Y, spec.HitboxSize.Z) <= 0
        or typeof(spec.CFrameOffset) ~= "CFrame"
        or type(spec.ActiveStart) ~= "number" or spec.ActiveStart ~= spec.ActiveStart
        or type(spec.ActiveEnd) ~= "number" or spec.ActiveEnd ~= spec.ActiveEnd
        or spec.ActiveStart < 0 or spec.ActiveEnd < spec.ActiveStart
        or spec.ActiveEnd > 4 or spec.CustomCFrame ~= nil then
        return false
    end
    -- This adapter handles attached melee/area boxes. Moving custom boxes
    -- require their caller's trajectory and are deliberately not registered.
    self.ConfirmedHBProfiles[id] = table.clone(spec)
    return true
end

function State:GetHBProfile(threat)
    if threat.PhysicalProjectile or threat.Profile.Kind == "Ranged" then return nil end
    return self.ConfirmedHBProfiles[normalizeAnimationId(threat.TimingKey)]
end

function State:HBVelocityOffset(velocity, enabled, noPrediction)
    if enabled ~= true or noPrediction or not finiteVector(velocity) then return ZERO end
    return clampMagnitude(Vector3.new(velocity.X, 0, velocity.Z) * 0.1, 10)
end

function State:HBBoxAt(threat, spec, timeAhead, hypothesisOffset)
    local motion = threat.AttackerMotion
    if not motion then return nil end
    local character = threat.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not root then return nil end
    local position = predictPosition(motion, timeAhead, true, threat.DashAttack)
        + self:ProvisionalDashOffset(threat, motion, timeAhead)
        + (hypothesisOffset or ZERO)
    local frame = CFrame.new(position) * root.CFrame.Rotation * spec.CFrameOffset
    local player = Players:GetPlayerFromCharacter(character)
    frame += self:HBVelocityOffset(root.AssemblyLinearVelocity,
        spec.VelocityPrediction, not player or player:GetAttribute("NoHitboxPredict"))
    local multiplier = Values:FindFirstChild("HitboxMultiplier")
    local scale = multiplier and tonumber(multiplier.Value) or 1
    if not scale or scale ~= scale or scale < 0 or scale == math.huge then return nil end
    return frame, spec.HitboxSize * scale
end

function State:HBTargetAllowed(attacker, target, spec)
    if not target or not target.Parent or attacker == target then return false end
    local root = target:FindFirstChild("HumanoidRootPart")
    if spec.UsePrimaryPartInstead then root = target.PrimaryPart end
    local humanoid = target:FindFirstChildOfClass("Humanoid")
    if not root or not spec.NoHumanoidCheck and not humanoid then return false end
    if spec.CantHitDeadPeople and (target:FindFirstChild("Dead") or humanoid and humanoid.Health <= 0) then return false end
    if spec.DeadPeopleOnly and not target:FindFirstChild("Dead") then return false end
    if attacker and target:GetAttribute("Tag") == attacker.Name then return false end
    if spec.IgnoreTag and target:GetAttribute("Tag") == spec.IgnoreTag then return false end
    if spec.CantHitThisFolder and target:FindFirstChild(spec.CantHitThisFolder) then return false end
    if spec.CantHitGuards and target:FindFirstChild("TypeOfGuard")
        and (not target:FindFirstChild("Enemy") or attacker and attacker:FindFirstChild("TypeOfGuard")) then return false end
    if spec.CantHitRagdoll and target:FindFirstChild("Ragdoll") then return false end
    if spec.IgnoreTargetsTbl and table.find(spec.IgnoreTargetsTbl, target) then return false end
    if spec.IgnoreWakeup and target:FindFirstChild("SuperArmorGetUp") then return false end
    if spec.OnlyHitRagdollAndWakeup and not (target:FindFirstChild("Ragdoll") or target:FindFirstChild("SuperArmorGetUp")) then return false end
    -- Modules.HB's IFrame branch handles counters but does not insert the
    -- target in its ordinary hit-result table, even with IFramePower set.
    if target:FindFirstChild("IFrame") then return false end
    if spec.RagdollWakeupImmunityLess and target:FindFirstChild("RagdollWakeupImmunityLess") then return false end
    local player = Players:GetPlayerFromCharacter(target)
    if player then
        if spec.CantHitHunters and player:GetAttribute("IsHunter") then return false end
        if spec.OnlyHitHunters and not player:GetAttribute("IsHunter") then return false end
        if spec.IgnorePlayerGuards and player:GetAttribute("IsGuard") then return false end
    end
    local source = attacker and Players:GetPlayerFromCharacter(attacker)
    if workspace:GetAttribute("RebelFight") and source and player
        and not source:GetAttribute("IsGuard") and not player:GetAttribute("IsGuard") then
        return false
    end
    return true
end

function State:HBBodyClearance(frame, size, body, padding)
    -- Exact segment-to-box distance for the existing vertical body capsule.
    -- This remains a body approximation, not Roblox's per-limb overlap query.
    local first = frame:PointToObjectSpace(body - Vector3.new(0, BODY_HALF_HEIGHT, 0))
    local last = frame:PointToObjectSpace(body + Vector3.new(0, BODY_HALF_HEIGHT, 0))
    local delta = last - first
    local half = size * 0.5
    local cuts = { 0, 1 }
    for _, axis in ipairs({ "X", "Y", "Z" }) do
        if math.abs(delta[axis]) > 0.000001 then
            for _, bound in ipairs({ -half[axis], half[axis] }) do
                local t = (bound - first[axis]) / delta[axis]
                if t > 0 and t < 1 then cuts[#cuts + 1] = t end
            end
        end
    end
    table.sort(cuts)
    local best = math.huge
    for i = 1, #cuts - 1 do
        local lo, hi = cuts[i], cuts[i + 1]
        local mid = (lo + hi) * 0.5
        local a, b = 0, 0
        for _, axis in ipairs({ "X", "Y", "Z" }) do
            local value = first[axis] + delta[axis] * mid
            local bound = value < -half[axis] and -half[axis]
                or value > half[axis] and half[axis] or nil
            if bound then
                a += delta[axis] * delta[axis]
                b += delta[axis] * (first[axis] - bound)
            end
        end
        local t = a > 0 and math.clamp(-b / a, lo, hi) or lo
        local point = first + delta * t
        local excess = Vector3.new(math.max(0, math.abs(point.X) - half.X),
            math.max(0, math.abs(point.Y) - half.Y), math.max(0, math.abs(point.Z) - half.Z))
        best = math.min(best, excess:Dot(excess))
    end
    return math.sqrt(best) - BODY_RADIUS - math.max(0, padding or 0)
end

function State:HBLineOfSight(threat, spec, frame, targetPosition)
    if not (spec.RequiresLOS or spec.RequiresLOSROOT or spec.RequiresLOSProjectile) then return true end
    local root = threat.Character and threat.Character:FindFirstChild("HumanoidRootPart")
    if not root then return false end
    local parameters = RaycastParams.new()
    parameters.FilterType = Enum.RaycastFilterType.Exclude
    local filter = { Live }
    local effects = workspace:FindFirstChild("Effects")
    if effects then filter[#filter + 1] = effects end
    parameters.FilterDescendantsInstances = filter
    local function clear(origin, target)
        return workspace:Raycast(origin, target - origin, parameters) == nil
    end
    if spec.RequiresLOSProjectile and not clear(frame.Position, targetPosition) then return false end
    if spec.RequiresLOSROOT and (not clear(root.Position, targetPosition)
        or not clear((root.CFrame * CFrame.new(0, 0, 0.5)).Position, targetPosition)) then return false end
    if spec.RequiresLOS and not clear(root.Position, targetPosition) then
        local target = LocalPlayer.Character
        local targetRoot = target and target:FindFirstChild("HumanoidRootPart")
        if not targetRoot then return false end
        local shift = targetPosition - targetRoot.Position
        local head = threat.Character:FindFirstChild("Head")
        local targetHead = target:FindFirstChild("Head")
        if head and targetHead then
            local origin = head.Position + Vector3.new(0, 2, 0)
            local direction = targetHead.Position + shift - (root.Position + Vector3.new(0, 2, 0))
            if workspace:Raycast(origin, direction, parameters) == nil then return true end
        end
        for _, name in ipairs({ "Right Arm", "Left Arm", "Left Leg", "Right Leg", "Torso" }) do
            if not (spec.DontCheckArms and (name == "Right Arm" or name == "Left Arm")) then
                local a, b = threat.Character:FindFirstChild(name), target:FindFirstChild(name)
                if a and b and clear(a.Position, b.Position + shift) then return true end
            end
        end
        return false
    end
    return true
end

function State:HBContactTime(threat, spec, localMotion, startTime, endTime, padding)
    local target = LocalPlayer.Character
    if not self:HBTargetAllowed(threat.Character, target, spec) then return nil end
    local count = 16
    local duration = math.max(0, endTime - startTime)
    for i = 0, count do
        local t = startTime + duration * i / count
        local frame, size = self:HBBoxAt(threat, spec, t)
        if frame then
            local body = predictPosition(localMotion, t, true)
            if self:HBBodyClearance(frame, size, body, padding) <= 0
                and self:HBLineOfSight(threat, spec, frame, body) then
                return t
            end
        end
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
    local hbSpec = State:GetHBProfile(threat)
    if hbSpec then
        local frame, size = State:HBBoxAt(threat, hbSpec, timeAhead)
        return frame ~= nil and State:HBTargetAllowed(threat.Character, LocalPlayer.Character, hbSpec)
            and State:HBBodyClearance(frame, size, localPosition, uncertainty) <= 0
    end
    local attackerPosition = predictPosition(
        attackerMotion,
        timeAhead,
        withAcceleration,
        threat.DashAttack
    ) + State:ProvisionalDashOffset(threat, attackerMotion, timeAhead)

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
    if threat.Character and threat.Character == LocalPlayer.Character then
        threat.ContactIn = nil
        threat.Emergency = false
        threat.Deadline = math.huge
        return false, "self attack"
    end
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
    if not threat.RangedReleased
        and State:IsCancelledAttack(threat, cancellationPhase) then
        State:ObserveCancellationAudit(threat)
        threat.ContactIn = nil
        threat.Emergency = false
        threat.Deadline = math.huge
        State:ClearReactionConfirmation(threat)
        return false, "cancelled before active"
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
    local dashDirection = recentDash and recentDash >= now
        and State.RecentEnemyDashDirections[attackerCharacter]
        or threat.DashDirection
    local dashWalkBridgeUntil = recentDash and recentDash >= now
        and State.RecentEnemyDashWalkBridgeUntil[attackerCharacter]
        or threat.DashWalkBridgeUntil
    local dashWalkBridge = dashHint
        and (dashWalkBridgeUntil or 0) >= now
    if dashHint and dashDirection then
        threat.DashDirection = dashDirection
    end
    local baseReach = math.max(
        profile.Range or 0,
        profile.FarReach or 0,
        profile.Radius or 0
    ) + BODY_RADIUS
    local facingDot = threat.LookDirection:Dot(targetDirection)
    local dashAligned = attackerApproachSpeed >= DASH_CONFIRM_MIN_SPEED
        and attackerAlignment >= DASH_CONFIRM_DOT
    local provisionalDirection = State:DashDirectionVector(
        attackerCharacter,
        dashDirection,
        threat.LookDirection
    )
    local dashDirectionDot = provisionalDirection:Dot(targetDirection)
    local horizontalAttackerSpeed = Vector3.new(
        attackerVelocity.X,
        0,
        attackerVelocity.Z
    ).Magnitude
    local walkDash = State:IsWalkDashAligned(
        dashWalkBridge,
        dashDirection,
        horizontalAttackerSpeed,
        dashDirectionDot
    )
    local closeDash = currentDistance <= baseReach + 2
        and dashDirectionDot >= 0.35
    if dashHint and (dashAligned or closeDash or walkDash)
        or attackerApproachSpeed >= DASH_CLOSING_SPEED
            and attackerAlignment >= DASH_CONFIRM_DOT
        or attackerApproachAcceleration >= DASH_CLOSING_ACCELERATION
            and dashAligned then
        threat.DashConfirmedUntil = now + DASH_CONFIRM_HOLD
    end
    -- Dash animations are only hints.  A sideways/away dash must not remain
    -- latched as an incoming attack for the rest of the animation.
    threat.DashAttack = (threat.DashConfirmedUntil or 0) >= now

    local provisionalDash = walkDash and not dashAligned
    if provisionalDash then
        local provisionalSpeed = State:ProvisionalForwardDashDistance(
            attackerCharacter,
            0.001
        ) / 0.001
        threat.ProvisionalDash = true
        threat.ProvisionalDashDirection = provisionalDirection
        threat.ProvisionalDashVelocity = provisionalDirection
            * provisionalSpeed
        threat.ProvisionalDashExpiresAt = dashWalkBridgeUntil
    else
        threat.ProvisionalDash = nil
        threat.ProvisionalDashDirection = nil
        threat.ProvisionalDashVelocity = nil
        threat.ProvisionalDashExpiresAt = nil
    end

    local relativeVelocity = localMotion.Velocity
        - (threat.ProvisionalDashVelocity
            or predictionVelocity(attackerMotion, threat.DashAttack))
    local relativeAcceleration = localMotion.Acceleration
        - attackerMotion.Acceleration
    local closingSpeed = currentDistance > 0.01
        and -relativePosition.Unit:Dot(relativeVelocity)
        or 0

    local lead = getPredictionLead(profile, threat.TimingKey)
    local hbSpec = State:GetHBProfile(threat)
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
    threat.FacingDot = facingDot
    if hbSpec then
        relevant = State:HBTargetAllowed(attackerCharacter, localCharacter, hbSpec)
        relevanceReason = relevant and "confirmed HB" or "HB target excluded"
    end
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
            State:ClearReactionConfirmation(threat)
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
    if hbSpec then
        emergency = false
        contactTime = State:HBContactTime(threat, hbSpec, localMotion,
            activeStart, activeEnd, uncertainty)
    elseif emergency then
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
                    ) - State:ProvisionalDashOffset(
                        threat,
                        attackerMotion,
                        sampleTime
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
                    threat.ProvisionalDashVelocity
                        or predictionVelocity(attackerMotion, true),
                    threat.LookDirection
                ):Dot(targetDirection)
                if not contactTime and threat.DashAttack
                    and profile.TravelHitbox == true
                    and attackerApproachSpeed > 3
                    and travelAlignment > 0.25 then
                    if attackHitsAt(
                        threat, broadEntry, localMotion, attackerMotion,
                        uncertainty, nil, true
                    ) then
                        contactTime = broadEntry
                    end
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
        State:ClearReactionConfirmation(threat)
    end
    if contactTime and not threat.CountedPrediction then
        threat.CountedPrediction = true
        threat.FirstConfirmedAt = os.clock()
        State.PredictedThreats += 1
        State:ObservePredictionAudit(threat)
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
            return specification.Canonical or key, specification
        end
    end
    for _, attributeName in ipairs({
        "ProjectileType", "WeaponType", "Weapon", "ItemType",
    }) do
        local value = object:GetAttribute(attributeName)
        local key = normalizedObjectName(value)
        if PROJECTILE_SIGNATURES[key] and not hasGunToken(value) then
            local specification = PROJECTILE_SIGNATURES[key]
            return specification.Canonical or key, specification
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
    walkDescendantsBounded(object, 96, function(descendant)
        if descendant:IsA("BasePart") and not hasGunToken(descendant.Name) then
            local size = descendant.Size
            local volume = size.X * size.Y * size.Z
            if volume > bestVolume then
                best = descendant
                bestVolume = volume
            end
        end
    end)
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

local function registerProjectile(object, generation, historicalScan)
    if not State.Enabled or generation ~= State.Generation
        or not Effects or not object or not object:IsDescendantOf(Effects) then
        return nil
    end
    local signature, specification
    local projectileObject
    local cursor = object
    -- Effects can nest a projectile under several Models. Prefer the highest
    -- recognized container so one physical object is tracked only once.
    while cursor and cursor ~= Effects do
        local candidateSignature, candidateSpecification =
            projectileSignatureFor(cursor)
        if candidateSignature then
            projectileObject = cursor
            signature = candidateSignature
            specification = candidateSpecification
        end
        cursor = cursor.Parent
    end
    if not signature then
        return nil
    end
    object = projectileObject or object
    if State.Projectiles[object] then
        return State.Projectiles[object]
    end
    local part = largestPartIn(object)
    if not part or hasGunToken(part.Name) then
        return nil
    end
    local initialLinearSpeed = part.AssemblyLinearVelocity.Magnitude
    local initialAngularSpeed = part.AssemblyAngularVelocity.Magnitude
        * math.max(0.5, part.Size.Magnitude * 0.5)
    if historicalScan and part.Anchored
        and math.max(initialLinearSpeed, initialAngularSpeed)
            < PROJECTILE_PROOF_SPEED then
        -- Existing anchored effects are overwhelmingly old decorations (the
        -- live game can retain dozens of Effects.rock instances). New anchored
        -- tween projectiles are still admitted by DescendantAdded and receive
        -- a short finite-difference probation window below.
        return nil
    end
    if State.ProjectileCount >= MAX_PROJECTILES then
        -- A burst of decorative effects must not lock a real new projectile
        -- out of the fixed-cap tracker. Evict one unproven probation record.
        for index = #State.ProjectileList, 1, -1 do
            local candidate = State.ProjectileList[index]
            if candidate and not candidate.MotionProven
                and not candidate.Threat then
                State.Projectiles[candidate.Object] = nil
                local lastIndex = #State.ProjectileList
                State.ProjectileList[index] = State.ProjectileList[lastIndex]
                State.ProjectileList[lastIndex] = nil
                State.ProjectileCount = #State.ProjectileList
                break
            end
        end
        if State.ProjectileCount >= MAX_PROJECTILES then
            return nil
        end
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
        SpawnedNearLocal = false,
        MotionProven = math.max(initialLinearSpeed, initialAngularSpeed)
            >= PROJECTILE_PROOF_SPEED,
        ProbationUntil = os.clock() + PROJECTILE_MOTION_PROBATION,
        HistoricalScan = historicalScan == true,
    }
    local _, _, localRoot = getLocalCharacter()
    if localRoot then
        local localDistance = (boxCFrame.Position - localRoot.Position).Magnitude
        -- Spawn proximity is telemetry, never ownership. Enemy projectiles can
        -- replicate beside the local player; suppressing them permanently was
        -- a lethal false negative. Explicit owner metadata or animation fusion
        -- is required to call a projectile locally owned.
        record.SpawnedNearLocal = localDistance < 11
    end
    local ownerUserId = object:GetAttribute("OwnerUserId")
        or object:GetAttribute("UserId")
    if tonumber(ownerUserId) == LocalPlayer.UserId then
        record.LocalOwned = true
    end
    State.Projectiles[object] = record
    State.ProjectileList[#State.ProjectileList + 1] = record
    State.ProjectileCount += 1
    State.ProjectileCandidatesSeen += 1
    return record
end

function State:ScanProjectileEffects(generation, limit)
    if not Effects then
        return
    end
    limit = math.clamp(math.floor(tonumber(limit) or 256), 1, 512)
    local queue = Effects:GetChildren()
    local cursor = 1
    while cursor <= #queue and cursor <= limit do
        local object = queue[cursor]
        cursor += 1
        registerProjectile(object, generation, true)
        if #queue < limit then
            for _, child in ipairs(object:GetChildren()) do
                if #queue >= limit then
                    break
                end
                queue[#queue + 1] = child
            end
        end
    end
    table.clear(queue)
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
        record.MotionProven = record.MotionProven
            or record.Velocity.Magnitude >= PROJECTILE_PROOF_SPEED
            or record.AngularVelocity.Magnitude
                * math.max(0.5, record.Radius or 0.5)
                    >= PROJECTILE_PROOF_SPEED
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
    record.MotionProven = record.MotionProven
        or speed >= PROJECTILE_PROOF_SPEED
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
            State:MergeReactionConfirmation(best, previousThreat, now)
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
        State:ClearReactionConfirmation(threat)
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
    State:ScanProjectileEffects(generation, 512)
    State.NextProjectileRescanAt = os.clock() + 1.5
    State.ProjectileEffectsConnection = Effects.DescendantAdded:Connect(guarded(
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
                    if updated and record.MotionProven then
                        associateProjectile(record, now)
                        createPhysicalThreat(record, now, localMotion)
                    end
                    return updated and (
                        record.MotionProven
                        or now < (record.ProbationUntil or now)
                    )
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
        State:ScanProjectileEffects(State.Generation, 512)
    end
end

local function startProjectileTracking(generation)
    bindProjectileEffects(generation)
end

local function retireCoveredThreats(now, primary)
    -- Verified movement is not proof that a tracking/combo attack ended.
    -- Keep the active attack in prediction; native cooldowns and the existing
    -- per-threat two-request limit continue to bound additional actions.
    if primary then primary.LastVerifiedDodgeAt = now end
    for index = #State.Pending, 1, -1 do
        local threat = State.Pending[index]
        if threat.ExpiresAt <= now then
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
        State:RollbackPhantomFallbackSpend(
            character,
            attempt.FallbackSpendRecorded,
            attempt.BeforeRecentDash
        )
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
    local controller = State:ResolveDashControllerState(character)
    local newMover = root and State:FindNewDashVelocityMover(root, attempt.PreexistingMovers or {})
    local nativeAcknowledged, nativeAckSource = State:NativeDashAcknowledgement(
        attempt, controller, attributeAcknowledged, newMover, phantomStackAcknowledged
    )
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
        local projectedDistance = horizontalDisplacement:Dot(
            attempt.Direction
        )
        local projectedSpeed = horizontalVelocity:Dot(attempt.Direction)
        local velocityDot = horizontalVelocity.Magnitude > 1
            and horizontalVelocity.Unit:Dot(attempt.Direction) or -1
        local displacementDot = horizontalDisplacement.Magnitude > 0.05
            and horizontalDisplacement.Unit:Dot(attempt.Direction) or -1
        attempt.PeakDirectionDistance = math.max(
            attempt.PeakDirectionDistance or 0,
            projectedDistance
        )
        attempt.PeakDirectionSpeed = math.max(
            attempt.PeakDirectionSpeed or 0,
            projectedSpeed
        )
        attempt.PeakDirectionDot = math.max(
            attempt.PeakDirectionDot or -1,
            velocityDot,
            displacementDot
        )
        directionVerified = State:DashMotionVerified(
            projectedDistance,
            projectedSpeed,
            displacementDot,
            velocityDot,
            elapsedSinceRequest
        )
        directionVerified = directionVerified and (nativeAcknowledged or attempt.Acknowledged == true)
        if directionVerified then
            attempt.MotionVerified = true
            if not attempt.MotionTimingRecorded and (attempt.PeakDirectionDistance or 0)>=1.25
                and attempt.Telemetry and not attempt.Telemetry.Rejected then
                local mode=attempt.Telemetry and attempt.Telemetry.NativeMode or "Normal"
                State:RecordTimingSample("Startup:"..mode,now-attempt.RequestedAt,now)
                attempt.MotionTimingRecorded=true
            end
        end
    end

    if nativeAcknowledged
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
        attempt.AckSource = directionVerified and "Motion" or nativeAckSource
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
        -- A controller ACK can arrive near the original release-relative
        -- timeout.  Once acknowledged, always preserve the complete physical
        -- verification grace instead of rejecting it on the next frame.
        State:PreserveDashVerificationGrace(attempt, now)
    end

    local accepted = State:DashAcknowledgementReady(
        attempt,
        now,
        directionVerified
    )
    if accepted then
        restoreDirectionLease(attempt.LeaseToken, false)
        if attempt.Telemetry then
            attempt.Telemetry.Accepted = true
        end
        State.AcceptedDodges += 1
        State:AcknowledgeDodgeAudit(attempt, directionVerified)
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
        State.LastDashDirectionDot = attempt.PeakDirectionDot or 0
        State.LastDashDirectionDistance = attempt.PeakDirectionDistance or 0
        State.LastDashDirectionSpeed = attempt.PeakDirectionSpeed or 0
        State.LastDashAckSource = directionVerified
            and "Motion" or attempt.AckSource or "Unknown"
        pushReplay("dodge_accepted", now, {
            Threat = State.LastThreat,
            Direction = State.LastDirection,
            Verified = directionVerified,
            Reaction = State.LastReactionMilliseconds,
            Ack = State.LastAcknowledgementMilliseconds,
            AckSource = State.LastDashAckSource,
            PeakDot = State.LastDashDirectionDot,
            PeakDistance = State.LastDashDirectionDistance,
            PeakSpeed = State.LastDashDirectionSpeed,
            BeforeReady = attempt.BeforePhantomReady or 0,
            BeforeMaximum = attempt.BeforePhantomMaximum or 0,
            StateSource = attempt.BeforePhantomSource or "Native",
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
        State:RollbackPhantomFallbackSpend(
            character,
            attempt.FallbackSpendRecorded,
            attempt.BeforeRecentDash
        )
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

local function getDashDistance(character, timeAhead, analyticOnly)
    local model = State:GetNativeDashModel(character)
    local analytic = State:NativeDashDistanceFromModel(model, timeAhead)
    if analyticOnly or model.Duration <= 0.05 then return analytic end
    return State:CalibratedDashDistance(
        State:CurrentDashCalibrationKey(character, false),
        math.clamp(timeAhead, 0, model.Duration), analytic
    )
end

function State:ClearMapIndex()
    clearConnections(self.MapConnections)
    table.clear(self.MapConnections)
    table.clear(self.MapRoots)
    table.clear(self.EventMapRoots)
    table.clear(self.MapPartList)
    table.clear(self.MapHazardList)
    table.clear(self.MapBarrierList)
    table.clear(self.MapDynamicList)
    table.clear(self.MapScanQueue)
    self.MapRegistry = setmetatable({}, { __mode = "k" })
    self.EventMapMembership = setmetatable({}, { __mode = "k" })
    self.MapQueued = setmetatable({}, { __mode = "k" })
    self.MapRoleCache = setmetatable({}, { __mode = "k" })
    self.MapHazardMembership = setmetatable({}, { __mode = "k" })
    self.MapBarrierMembership = setmetatable({}, { __mode = "k" })
    self.MapDynamicMembership = setmetatable({}, { __mode = "k" })
    self.MapHazardListed = setmetatable({}, { __mode = "k" })
    self.MapBarrierListed = setmetatable({}, { __mode = "k" })
    self.MapDynamicListed = setmetatable({}, { __mode = "k" })
    self.MapMotion = setmetatable({}, { __mode = "k" })
    self.MapScanCursor = 1
    self.MapScanTail = 0
    self.MapMotionCursor = 1
    self.MapDynamicCursor = 1
    self.MapAuditTotal = 0
    self.MapAuditScanned = 0
    self.MapRegisteredCount = 0
    self.MapAuditParts = 0
    self.MapAuditModels = 0
    self.MapAuditComplete = false
    self.MapMovingParts = 0
    self.MapHazardCount = 0
    self.MapBarrierCount = 0
    self.MapDynamicCount = 0
    self.MapRootCount = 0
    self.MapTombstones = 0
    self.MapRevisionFrameToken = -1
end

function State:IsMapRoot(instance)
    return instance ~= nil
        and (instance:IsA("Folder") or instance:IsA("Model"))
        and string.lower(instance.Name) == "map"
end

function State:IsMapMember(instance)
    local current = instance
    while current and current ~= workspace do
        for _, root in ipairs(self.MapRoots) do
            if root and root.Parent == workspace and current == root then
                return true
            end
        end
        current = current.Parent
    end
    return false
end

function State:AddEventMapRoot(instance)
    if not instance or instance.Parent ~= workspace
        or instance:GetAttribute("EventMap") == nil
        or self.EventMapMembership[instance] then
        return false
    end
    self.EventMapMembership[instance] = true
    self.EventMapRoots[#self.EventMapRoots + 1] = instance
    return true
end

function State:RemoveEventMapRoot(instance)
    if not instance or not self.EventMapMembership[instance] then
        return false
    end
    self.EventMapMembership[instance] = nil
    for index = #self.EventMapRoots, 1, -1 do
        if self.EventMapRoots[index] == instance
            or not self.EventMapRoots[index]
            or self.EventMapRoots[index].Parent ~= workspace then
            local last = self.EventMapRoots[#self.EventMapRoots]
            self.EventMapRoots[index] = last
            self.EventMapRoots[#self.EventMapRoots] = nil
        end
    end
    return true
end

function State:QueueMapInstance(instance)
    if not instance or self.MapQueued[instance] then
        return false
    end
    self.MapQueued[instance] = true
    self.MapScanTail += 1
    self.MapScanQueue[self.MapScanTail] = instance
    self.MapAuditTotal += 1
    self.MapAuditComplete = false
    return true
end

function State:DirectGeometryRole(instance)
    if not instance then
        return false, false, false
    end
    local lower = string.lower(tostring(instance.Name or ""))
    local barrier = lower == "barriers"
        or string.find(lower, "barrier", 1, true) ~= nil
        or string.find(lower, "invwall", 1, true) ~= nil
        or string.find(lower, "inviswall", 1, true) ~= nil
        or string.find(lower, "blocking", 1, true) ~= nil
    local hazard = false
    local dynamic = false
    for _, signal in ipairs(self.HazardNameSignals) do
        if string.find(lower, signal, 1, true) then
            hazard = true
            break
        end
    end
    if not hazard then
        for _, signal in ipairs(self.MapRoleSignals) do
            local matched = signal ~= "barrier" and (
                string.sub(lower, 1, #signal) == signal
                or string.sub(lower, -#signal) == signal
            )
            if signal == "kill" then
                matched = matched
                    or string.find(lower, "killpart", 1, true) ~= nil
                    or string.find(lower, "killzone", 1, true) ~= nil
                    or string.find(lower, "instakill", 1, true) ~= nil
            elseif signal == "void" then
                matched = matched
                    or string.find(lower, "voidfloor", 1, true) ~= nil
                    or string.find(lower, "voidpart", 1, true) ~= nil
                    or string.find(lower, "voidzone", 1, true) ~= nil
            elseif signal == "damage" then
                matched = matched
                    or string.find(lower, "damagefloor", 1, true) ~= nil
                    or string.find(lower, "damagepart", 1, true) ~= nil
                    or string.find(lower, "damagezone", 1, true) ~= nil
            end
            if matched then
                hazard = true
                break
            end
        end
    end
    for _, signal in ipairs(self.MapDynamicSignals) do
        if string.find(lower, signal, 1, true) then
            dynamic = true
            break
        end
    end
    for _, signal in ipairs(self.HazardBooleanSignals) do
        local value = instance:GetAttribute(signal)
        if value == true or type(value) == "number" and value > 0 then
            hazard = true
        end
    end
    for _, name in ipairs({
        "Damage", "TouchDamage", "LethalDamage", "InstantKill",
        "Kill", "Kills", "Hazard", "Lethal", "Unsafe",
        "damage", "touchdamage", "lethaldamage", "instantkill",
        "kill", "kills", "hazard", "lethal", "unsafe",
    }) do
        local value = instance:GetAttribute(name)
        if value == true or type(value) == "number" and value > 0 then
            hazard = true
        end
        local child = instance:FindFirstChild(name)
        if child and child:IsA("ValueBase") then
            local ok, childValue = pcall(function()
                return child.Value
            end)
            if ok and (childValue == true
                or type(childValue) == "number" and childValue > 0) then
                hazard = true
            end
        end
    end
    local okAttributes, attributes = pcall(instance.GetAttributes, instance)
    if okAttributes then
        for name, value in pairs(attributes) do
            local key = string.lower(tostring(name))
            if value == true or type(value) == "number" and value > 0 then
                if string.find(key, "damage", 1, true)
                    or string.find(key, "kill", 1, true)
                    or string.find(key, "hazard", 1, true)
                    or string.find(key, "lethal", 1, true)
                    or string.find(key, "unsafe", 1, true) then
                    hazard = true
                end
            end
        end
    end
    local collectionService = game:GetService("CollectionService")
    for _, signal in ipairs(self.HazardBooleanSignals) do
        if collectionService:HasTag(instance, signal) then
            hazard = true
        end
    end
    if collectionService:HasTag(instance, "Barrier")
        or collectionService:HasTag(instance, "Barriers") then
        barrier = true
    end
    if instance:IsA("BasePart") then
        local group = string.lower(instance.CollisionGroup)
        barrier = barrier or string.find(group, "barrier", 1, true) ~= nil
        hazard = hazard
            or string.find(group, "hazard", 1, true) ~= nil
            or string.find(group, "kill", 1, true) ~= nil
    end
    return barrier, hazard, dynamic
end

function State:GeometryRoleFor(instance, refresh)
    if not instance then
        return { Barrier = false, Hazard = false, Dynamic = false }
    end
    local cached = not refresh and self.MapRoleCache[instance]
    if cached then
        return cached
    end
    local barrier, hazard, dynamic = false, false, false
    local current = instance
    -- Do not cap this walk: maps commonly put collision parts several Models
    -- deep, and a fixed 12/16-parent ceiling silently loses their semantics.
    while current and current ~= workspace do
        local directBarrier, directHazard, directDynamic =
            self:DirectGeometryRole(current)
        barrier = barrier or directBarrier
        hazard = hazard or directHazard
        dynamic = dynamic or directDynamic
        current = current.Parent
    end
    local role = {
        Barrier = barrier,
        Hazard = hazard,
        Dynamic = dynamic,
    }
    self.MapRoleCache[instance] = role
    return role
end

function State:InvalidateMapGeometry(reason)
    local now = os.clock()
    local frameToken = math.floor(now * 240)
    if frameToken ~= self.MapRevisionFrameToken then
        self.MapRevision += 1
        self.MapRevisionFrameToken = frameToken
    end
    self.MapChangedAt = now
    table.clear(self.TerrainResultCache)
    self.DodgePlan = nil
    self.LastTerrainStatus = reason or "Map changed"
end

function State:RefreshMapPartRole(part)
    if not part or not part.Parent or not part:IsA("BasePart") then
        return nil
    end
    self.MapRoleCache[part] = nil
    local role = self:GeometryRoleFor(part, true)
    local changed = false
    if role.Hazard and not self.MapHazardMembership[part] then
        changed = true
        self.MapHazardMembership[part] = true
        if not self.MapHazardListed[part] then
            self.MapHazardListed[part] = true
            self.MapHazardList[#self.MapHazardList + 1] = part
        end
        self.MapHazardCount += 1
    elseif not role.Hazard and self.MapHazardMembership[part] then
        changed = true
        self.MapHazardMembership[part] = nil
        self.MapHazardCount = math.max(0, self.MapHazardCount - 1)
    end
    if role.Barrier and not self.MapBarrierMembership[part] then
        changed = true
        self.MapBarrierMembership[part] = true
        if not self.MapBarrierListed[part] then
            self.MapBarrierListed[part] = true
            self.MapBarrierList[#self.MapBarrierList + 1] = part
        end
        self.MapBarrierCount += 1
    elseif not role.Barrier and self.MapBarrierMembership[part] then
        changed = true
        self.MapBarrierMembership[part] = nil
        self.MapBarrierCount = math.max(0, self.MapBarrierCount - 1)
    end
    local dynamic = role.Dynamic or not part.Anchored
    if dynamic and not self.MapDynamicMembership[part] then
        changed = true
        self.MapDynamicMembership[part] = true
        if not self.MapDynamicListed[part] then
            self.MapDynamicListed[part] = true
            self.MapDynamicList[#self.MapDynamicList + 1] = part
        end
        self.MapDynamicCount += 1
    elseif not dynamic and self.MapDynamicMembership[part] then
        changed = true
        self.MapDynamicMembership[part] = nil
        self.MapDynamicCount = math.max(0, self.MapDynamicCount - 1)
    end
    if changed and self.MapAuditComplete then
        self:InvalidateMapGeometry("Map role changed")
    end
    return role
end

function State:RegisterMapInstance(instance)
    if not instance or self.MapRegistry[instance] then
        return false
    end
    self.MapRegistry[instance] = true
    self.MapAuditScanned += 1
    self.MapRegisteredCount += 1
    if instance:IsA("Model") then
        self.MapAuditModels += 1
    elseif instance:IsA("BasePart") then
        self.MapAuditParts += 1
        self.MapPartList[#self.MapPartList + 1] = instance
        self:RefreshMapPartRole(instance)
        self:SampleMapPartMotion(instance, os.clock(), true)
    end
    return true
end

function State:SampleMapPartMotion(part, now, initialize)
    if not part or not part.Parent or not part:IsA("BasePart") then
        return nil
    end
    local sample = self.MapMotion[part]
    local ok, currentCFrame = pcall(function()
        return part.CFrame
    end)
    if not ok then
        return nil
    end
    if not sample then
        sample = {
            CFrame = currentCFrame,
            At = now,
            SurfaceSpeed = part.AssemblyLinearVelocity.Magnitude,
            Moving = false,
        }
        self.MapMotion[part] = sample
        return sample
    end
    local elapsed = now - (sample.At or now)
    if not initialize and elapsed >= 0.012 then
        local displacement = (currentCFrame.Position - sample.CFrame.Position).Magnitude
        local relative = sample.CFrame:ToObjectSpace(currentCFrame)
        local _, angle = relative:ToAxisAngle()
        local contactRadius = math.max(0.5, part.Size.Magnitude * 0.5)
        local finiteSpeed = displacement / elapsed
            + math.abs(angle) / elapsed * contactRadius
        local physicsSpeed = part.AssemblyLinearVelocity.Magnitude
            + part.AssemblyAngularVelocity.Magnitude * contactRadius
        local surfaceSpeed = math.max(finiteSpeed, physicsSpeed)
        local moving = surfaceSpeed * self.GroundSupportHorizon
            > self.MaximumSupportMotion
        if moving ~= sample.Moving then
            self.MapMovingParts += moving and 1 or -1
            self.MapMovingParts = math.max(0, self.MapMovingParts)
            if self.MapAuditComplete then
                self:InvalidateMapGeometry(
                    moving and "Map geometry moving" or "Map geometry settled"
                )
            end
        end
        sample.SurfaceSpeed = surfaceSpeed
        sample.Moving = moving
        sample.Displacement = displacement
        sample.AngularChange = math.abs(angle)
        sample.CFrame = currentCFrame
        sample.At = now
    elseif initialize then
        sample.CFrame = currentCFrame
        sample.At = now
    end
    return sample
end

function State:ProcessMapAudit(now)
    if not self.Enabled then
        return
    end
    if self.MapAuditComplete and self.MapTombstones > 128 then
        self:BeginMapAudit(self.Generation)
        return
    end
    if self.MapAuditComplete and (
        #self.MapHazardList > math.max(64, self.MapHazardCount * 2 + 16)
        or #self.MapBarrierList > math.max(64, self.MapBarrierCount * 2 + 16)
        or #self.MapDynamicList > math.max(96, self.MapDynamicCount * 2 + 24)
    ) then
        -- Rebuild through the normal chunked scanner instead of performing a
        -- synchronous full-list compaction on one frame.
        self:BeginMapAudit(self.Generation)
        return
    end
    local processed = 0
    while self.MapScanCursor <= self.MapScanTail
        and processed < self.MapScanPerFrame do
        if processed >= 32 and self.FrameBudgetActive
            and (self.FrameDeadline or 0) > 0
            and os.clock() >= self.FrameDeadline then
            break
        end
        local instance = self.MapScanQueue[self.MapScanCursor]
        self.MapScanQueue[self.MapScanCursor] = nil
        self.MapScanCursor += 1
        processed += 1
        if instance and self.MapQueued[instance]
            and instance.Parent and self:IsMapMember(instance) then
            self:RegisterMapInstance(instance)
            for _, child in ipairs(instance:GetChildren()) do
                self:QueueMapInstance(child)
            end
        elseif instance then
            self.MapQueued[instance] = nil
        end
    end
    if not self.MapAuditComplete
        and self.MapScanCursor > self.MapScanTail then
        self.MapAuditComplete = true
        table.clear(self.MapScanQueue)
        self.MapScanCursor = 1
        self.MapScanTail = 0
        self.LastTerrainStatus = self.MapRootCount > 0
            and string.format(
                "Map indexed %d/%d",
                self.MapAuditScanned,
                self.MapAuditTotal
            ) or "No Map model or folder"
    end
    local partCount = #self.MapPartList
    if partCount <= 0 then
        return
    end
    local dynamicCount = #self.MapDynamicList
    for dynamicIndex = 1, math.min(24, dynamicCount) do
        if dynamicIndex > 4 and self.FrameBudgetActive
            and (self.FrameDeadline or 0) > 0
            and os.clock() >= self.FrameDeadline then
            break
        end
        if self.MapDynamicCursor > dynamicCount then
            self.MapDynamicCursor = 1
        end
        local part = self.MapDynamicList[self.MapDynamicCursor]
        self.MapDynamicCursor += 1
        if part and part.Parent and self.MapRegistry[part] then
            self:SampleMapPartMotion(part, now, false)
            self:RefreshMapPartRole(part)
        end
    end
    for sampleIndex = 1, math.min(self.MapMotionSamplesPerFrame, partCount) do
        if sampleIndex > 4 and self.FrameBudgetActive
            and (self.FrameDeadline or 0) > 0
            and os.clock() >= self.FrameDeadline then
            break
        end
        if self.MapMotionCursor > partCount then
            self.MapMotionCursor = 1
        end
        local part = self.MapPartList[self.MapMotionCursor]
        self.MapMotionCursor += 1
        if part and part.Parent and self.MapRegistry[part] then
            self:SampleMapPartMotion(part, now, false)
            if sampleIndex <= 4 then
                self:RefreshMapPartRole(part)
            end
        end
    end
end

function State:BeginMapAudit(generation, discoveredRoot)
    self:ClearMapIndex()
    self:InvalidateMapGeometry("Indexing Map")
    -- Only direct Workspace Map containers are active collision maps. The
    -- game also stores effect/template Models named Map (for example IceKing)
    -- deeper in the tree; indexing those would create false terrain vetoes.
    local candidates = workspace:GetChildren()
    for _, instance in ipairs(candidates) do
        self:AddEventMapRoot(instance)
        if self:IsMapRoot(instance) then
            self.MapRoots[#self.MapRoots + 1] = instance
        end
    end
    if discoveredRoot and discoveredRoot.Parent
        and discoveredRoot.Parent == workspace
        and self:IsMapRoot(discoveredRoot) then
        local known = false
        for _, root in ipairs(self.MapRoots) do
            known = known or root == discoveredRoot
        end
        if not known then
            self.MapRoots[#self.MapRoots + 1] = discoveredRoot
        end
    end
    table.clear(candidates)
    self.MapRootCount = #self.MapRoots
    for _, root in ipairs(self.MapRoots) do
        self:QueueMapInstance(root)
        self.MapConnections[#self.MapConnections + 1] =
            root.DescendantAdded:Connect(guarded(
                "map descendant added",
                function(instance)
                    if State.Enabled and State.Generation == generation then
                        State:QueueMapInstance(instance)
                        State.MapRoleCache[instance] = nil
                        local ancestor = instance.Parent
                        while ancestor and ancestor ~= workspace do
                            State.MapRoleCache[ancestor] = nil
                            if ancestor:IsA("BasePart")
                                and State.MapRegistry[ancestor] then
                                State:RefreshMapPartRole(ancestor)
                                break
                            end
                            ancestor = ancestor.Parent
                        end
                        State:InvalidateMapGeometry("Map geometry added")
                    end
                end
            ))
        self.MapConnections[#self.MapConnections + 1] =
            root.DescendantRemoving:Connect(guarded(
                "map descendant removing",
                function(instance)
                    if State.Generation == generation then
                        local semanticParent = instance:IsA("ValueBase")
                            and instance.Parent or nil
                        if State.MapQueued[instance] then
                            State.MapAuditTotal = math.max(
                                0,
                                State.MapAuditTotal - 1
                            )
                        end
                        if State.MapRegistry[instance] then
                            State.MapTombstones += 1
                            State.MapRegisteredCount = math.max(
                                0,
                                State.MapRegisteredCount - 1
                            )
                            State.MapAuditScanned = math.max(
                                0,
                                State.MapAuditScanned - 1
                            )
                            if instance:IsA("Model") then
                                State.MapAuditModels = math.max(
                                    0,
                                    State.MapAuditModels - 1
                                )
                            elseif instance:IsA("BasePart") then
                                State.MapAuditParts = math.max(
                                    0,
                                    State.MapAuditParts - 1
                                )
                                if State.MapHazardMembership[instance] then
                                    State.MapHazardCount = math.max(
                                        0,
                                        State.MapHazardCount - 1
                                    )
                                end
                                if State.MapBarrierMembership[instance] then
                                    State.MapBarrierCount = math.max(
                                        0,
                                        State.MapBarrierCount - 1
                                    )
                                end
                                if State.MapDynamicMembership[instance] then
                                    State.MapDynamicCount = math.max(
                                        0,
                                        State.MapDynamicCount - 1
                                    )
                                end
                                local motion = State.MapMotion[instance]
                                if motion and motion.Moving then
                                    State.MapMovingParts = math.max(
                                        0,
                                        State.MapMovingParts - 1
                                    )
                                end
                            end
                        end
                        State.MapRegistry[instance] = nil
                        State.MapQueued[instance] = nil
                        State.MapRoleCache[instance] = nil
                        State.MapHazardMembership[instance] = nil
                        State.MapBarrierMembership[instance] = nil
                        State.MapDynamicMembership[instance] = nil
                        State.MapMotion[instance] = nil
                        State:InvalidateMapGeometry("Map geometry removed")
                        if semanticParent then
                            task.defer(guarded("map semantic refresh", function()
                                if not State.Enabled
                                    or State.Generation ~= generation then
                                    return
                                end
                                local ancestor = semanticParent
                                while ancestor and ancestor ~= workspace do
                                    State.MapRoleCache[ancestor] = nil
                                    if ancestor:IsA("BasePart")
                                        and State.MapRegistry[ancestor] then
                                        State:RefreshMapPartRole(ancestor)
                                        break
                                    end
                                    ancestor = ancestor.Parent
                                end
                            end))
                        end
                    end
                end
            ))
    end
    self.MapAuditComplete = self.MapScanTail == 0
    self.MapConnections[#self.MapConnections + 1] =
        workspace.ChildAdded:Connect(guarded(
            "map root added",
            function(instance)
                if State:AddEventMapRoot(instance) then
                    State:InvalidateMapGeometry("Event map added")
                end
                if State.Enabled and State.Generation == generation
                    and instance.Parent == workspace
                    and State:IsMapRoot(instance) then
                    task.defer(guarded("deferred map root add", function()
                        if State.Enabled and State.Generation == generation then
                            State:BeginMapAudit(generation, instance)
                        end
                    end))
                end
            end
        ))
    self.MapConnections[#self.MapConnections + 1] =
        workspace.ChildRemoved:Connect(guarded(
            "map root removing",
            function(instance)
                if State:RemoveEventMapRoot(instance) then
                    State:InvalidateMapGeometry("Event map removed")
                end
                if State.Enabled and State.Generation == generation
                    and State:IsMapRoot(instance) then
                    task.defer(guarded("deferred map root removal", function()
                        if State.Enabled and State.Generation == generation then
                            State:BeginMapAudit(generation)
                        end
                    end))
                end
            end
        ))
end

function State:SegmentIntersectsExpandedPart(startPosition, endPosition, part)
    if not part or not part.Parent then
        return false
    end
    local ok, hit = pcall(function()
        local first = part.CFrame:PointToObjectSpace(startPosition)
        local second = part.CFrame:PointToObjectSpace(endPosition)
        local delta = second - first
        local half = part.Size * 0.5
            + Vector3.new(BODY_RADIUS, BODY_HALF_HEIGHT, BODY_RADIUS)
        local enter, leave = 0, 1
        for axis = 1, 3 do
            local origin = axis == 1 and first.X
                or axis == 2 and first.Y or first.Z
            local movement = axis == 1 and delta.X
                or axis == 2 and delta.Y or delta.Z
            local extent = axis == 1 and half.X
                or axis == 2 and half.Y or half.Z
            if math.abs(movement) < 0.000001 then
                if origin < -extent or origin > extent then
                    return false
                end
            else
                local near = (-extent - origin) / movement
                local far = (extent - origin) / movement
                if near > far then
                    near, far = far, near
                end
                enter = math.max(enter, near)
                leave = math.min(leave, far)
                if enter > leave then
                    return false
                end
            end
        end
        return leave >= 0 and enter <= 1
    end)
    return ok and hit == true
end

function State:SweptMapRoleCollision(startPosition, pathVector, deadline)
    if deadline and os.clock() >= deadline then
        return nil, "Map role sweep deadline", false
    end
    if not self.MapAuditComplete then
        return nil, "Map audit pending", false
    end
    local endpoint = startPosition + pathVector
    local midpoint = startPosition + pathVector * 0.5
    local corridorRadius = pathVector.Magnitude * 0.5 + BODY_HALF_HEIGHT + 2
    local visited = 0
    for listIndex, list in ipairs({
        self.MapHazardList,
        self.MapBarrierList,
    }) do
        for _, part in ipairs(list) do
            if deadline and os.clock() >= deadline then
                return nil, "Map role sweep deadline", false
            end
            if part and part.Parent and self.MapRegistry[part]
                and self:IsMapMember(part) then
                local reach = part.Size.Magnitude * 0.5 + corridorRadius
                if (part.Position - midpoint).Magnitude <= reach then
                    visited += 1
                    if visited > self.MapHazardSweepLimit then
                        return nil, "Map role sweep budget", false
                    end
                    local role = self:GeometryRoleFor(part, true)
                    local relevant = listIndex == 1 and role.Hazard
                        or listIndex == 2 and role.Barrier
                    if relevant and self:SegmentIntersectsExpandedPart(
                        startPosition,
                        endpoint,
                        part
                    ) then
                        return part, role.Hazard
                            and "Hazard crosses dash path"
                            or "Barrier crosses dash path",
                            true
                    end
                end
            end
        end
    end
    return nil, nil, true
end

function State:TerrainDashDistance(character, timeAhead)
    local model = self:GetNativeDashModel(character)
    local analytic = getDashDistance(character, timeAhead, true)
    local upper
    if model.Duration <= 0.05 then
        -- task.delay(.05) stops the burst on a scheduled frame. Reserve one
        -- bounded observed frame in addition to the prior numerical margin.
        local stopMargin = math.min(self.NativeBurstStopFrameMargin,
            math.max(self.FrameMean, self.DecayingWorstFrame))
        upper = analytic * self.PhantomTerrainSafetyScale + model.InitialSpeed * stopMargin
    else
        upper = self:CalibratedDashUpperDistance(
            self:CurrentDashCalibrationKey(character, false),
            math.clamp(timeAhead, 0, model.Duration), analytic
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
    if character and self:IsPhantomStepActive(character) then
        for _, root in ipairs(self.EventMapRoots) do
            if root and root.Parent == workspace then
                filter[#filter + 1] = root
            end
        end
    end
    local parameters = RaycastParams.new()
    parameters.FilterType = Enum.RaycastFilterType.Exclude
    parameters.FilterDescendantsInstances = filter
    -- Water must remain visible to the support probe. The old IgnoreWater
    -- setting treated a water landing like empty/safe terrain in some maps.
    parameters.IgnoreWater = false
    parameters.RespectCanCollide = true
    if character then
        pcall(function()
            local root = character:FindFirstChild("HumanoidRootPart")
            if self:IsPhantomStepActive(character) then
                -- Match the game's real Phantom Step collision matrix. This
                -- retains Default map geometry and invisible Barriers.
                parameters.CollisionGroup = "PhantomStepDash"
            elseif root and root:IsA("BasePart") then
                parameters.CollisionGroup = root.CollisionGroup
            end
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
    local wall
    -- Root and upper-body sweeps catch waist walls and low ceilings without
    -- letting a foot-level sphere collide immediately with the floor.
    for _, height in ipairs({ 0, BODY_HALF_HEIGHT * 0.55 }) do
        local origin = startPosition + Vector3.new(0, height, 0)
        local ok, candidate = pcall(
            workspace.Spherecast,
            workspace,
            origin,
            height == 0 and self.GroundFootprintRadius or BODY_RADIUS * 0.8,
            pathVector,
            parameters
        )
        if not ok then
            candidate = workspace:Raycast(origin, pathVector, parameters)
        end
        if candidate and (not wall or candidate.Distance < wall.Distance) then
            wall = candidate
        end
    end
    if not wall then
        return pathVector, nil
    end
    local limitedDistance = math.max(0, wall.Distance - 0.15)
    return pathVector.Unit * limitedDistance, wall.Instance
end

function State:IsBarrierGeometry(instance)
    return self:GeometryRoleFor(instance, true).Barrier
end

function State:IsHazardGeometry(instance)
    return self:GeometryRoleFor(instance, true).Hazard
end

function State:IsWalkableSupport(result, roleCache, minimumNormalY)
    local part = result and result.Instance
    local role = part and roleCache and roleCache[part]
    if part and not role then
        local terrainHazard = part:IsA("Terrain") and result
            and (result.Material == Enum.Material.Water
                or result.Material == Enum.Material.CrackedLava)
        local physical = part:IsA("Terrain")
            or part:IsA("BasePart") and part.CanCollide and part.CanQuery
        local stable = true
        if part:IsA("BasePart") then
            local linearSpeed = part.AssemblyLinearVelocity.Magnitude
            local angularReach = result and
                (result.Position - part.Position).Magnitude
                or part.Size.Magnitude * 0.5
            local surfaceSpeed = linearSpeed
                + part.AssemblyAngularVelocity.Magnitude * angularReach
            local mapSample = self:SampleMapPartMotion(
                part,
                os.clock(),
                false
            )
            if mapSample and os.clock() - (mapSample.At or 0)
                <= self.MapMotionMaximumAge then
                surfaceSpeed = math.max(
                    surfaceSpeed,
                    mapSample.SurfaceSpeed or 0
                )
            end
            stable = surfaceSpeed * self.GroundSupportHorizon
                <= self.MaximumSupportMotion
        end
        role = {
            Physical = physical,
            Stable = stable,
            Barrier = self:IsBarrierGeometry(part),
            Hazard = terrainHazard or self:IsHazardGeometry(part),
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
    strictPhantom,
    deadline
)
    if deadline and os.clock() >= deadline then
        return false, "Ground sweep deadline", 0
    end
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
    -- Extend the segment count instead of refusing every route over 40 studs.
    -- Never widen gaps beyond the configured maximum or truncate the endpoint.
    local maximumSpacing = math.max(0.5, self.MaximumAdaptiveGroundSpacing)
    local hardLimit = math.clamp(
        math.floor(self.MaximumExtendedGroundSamples or self.MaximumGroundSamples),
        2, 96
    )
    local adaptiveSpacing = math.min(maximumSpacing, math.max(
        baseSpacing,
        travel / math.max(self.MaximumGroundSamples, 1)
    ))
    local segments = math.max(2, math.ceil(travel / adaptiveSpacing))
    self.LastGroundTravel = travel
    self.LastGroundCoverageLimit = hardLimit * maximumSpacing
    self.LastGroundSegments = segments
    self.LastGroundSpacing = travel / segments
    if segments > hardLimit then
        return false, "Ground coverage budget", 0
    end
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
        if deadline and segmentIndex > 0 and os.clock() >= deadline then
            return false, "Ground sweep deadline", minimumSupports
        end
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
            self.LastGroundFailure = {
                At = os.clock(), Reason = "Support clearance invalid",
                Clearance = centerClearance, Segment = segmentIndex,
                Point = { X = point.X, Y = point.Y, Z = point.Z },
                Support = string.sub(centerFloor.Instance:GetFullName(), 1, 192),
            }
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
        -- Center + both lateral rails are mandatory throughout. At landing,
        -- require one longitudinal rail as well; demanding all five rejected
        -- safe circular/narrow platforms even when the body footprint fit.
        local required = segmentIndex == segments and 4 or 3
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

function State:TerrainRetryBlocked(threat, now)
    if not threat.TerrainBlockedUntil or now >= threat.TerrainBlockedUntil then
        return false
    end
    if threat.TerrainCoveragePosition then
        local character = LocalPlayer.Character
        local root = character and character:FindFirstChild("HumanoidRootPart")
        if threat.TerrainCoverageRevision ~= self.MapRevision
            or not root
            or (root.Position - threat.TerrainCoveragePosition).Magnitude > 0.75 then
            threat.TerrainBlockedUntil = nil
            threat.TerrainCoveragePosition = nil
            return false
        end
    end
    return true
end

function State:IsTerrainCheckIncomplete(reason)
    return reason == "Terrain route deadline"
        or reason == "Ground sweep deadline"
        or reason == "Ground coverage budget"
        or reason == "Map role sweep deadline"
        or reason == "Map role sweep budget"
        or reason == "Map audit pending"
        or reason == "Cardinal terrain unavailable"
end

function State:EvaluateTerrainRouteUncached(
    character,
    localRoot,
    localMotion,
    direction,
    delay,
    parameters,
    strictPhantom,
    deadline
)
    if deadline and os.clock() >= deadline then
        return false, "Terrain route deadline", 0, ZERO, nil,
            localRoot.Position
    end
    local onset = math.max(0, tonumber(delay) or 0)
        + math.max(0, self.DashStartupMean)
    local startPosition = localRoot.Position
    if localMotion and onset > 0 then
        startPosition = predictPosition(localMotion, onset, true)
    end
    local path = self:TerrainPathVector(character, localMotion, direction)
    local burstClear, burstObstacle = self:NativeBurstPathClear(
        character, startPosition, path, self:GetNativeDashModel(character)
    )
    if not burstClear then
        return false, "Native burst would slow near obstacle", 0, path, burstObstacle, startPosition
    end
    local rolePart, roleReason, roleComplete = self:SweptMapRoleCollision(
        startPosition,
        path,
        deadline
    )
    if roleComplete == false then
        return false, roleReason, 0, path, nil, startPosition
    end
    if rolePart then
        return false, roleReason, 0, path, rolePart, startPosition
    end
    local limitedPath, obstacle = self:LimitTerrainPath(
        startPosition,
        path,
        parameters
    )
    if strictPhantom and obstacle then
        return false,
            self:IsBarrierGeometry(obstacle)
                and "Barrier obstructs Phantom path"
                or "Obstacle obstructs Phantom path",
            0,
            limitedPath,
            obstacle,
            startPosition
    end
    local safe, reason, supports = self:GroundPathSafe(
        startPosition,
        limitedPath,
        parameters,
        strictPhantom,
        deadline
    )
    return safe, reason, supports, limitedPath, obstacle, startPosition
end

function State:EvaluateTerrainRoute(
    character, localRoot, localMotion, direction, delay, parameters, strictPhantom, deadline, forceFresh
)
    -- Reuse only complete successful planning checks in this synchronous frame.
    -- The action preflight always bypasses this cache and probes the world again.
    local cacheable = self.FrameBudgetActive and not forceFresh and parameters ~= nil
    if deadline and os.clock() >= deadline then cacheable = false end
    if not cacheable then
        return self:EvaluateTerrainRouteUncached(
            character, localRoot, localMotion, direction, delay, parameters, strictPhantom, deadline
        )
    end
    local start = localRoot.Position
    local onset = math.max(0, tonumber(delay) or 0) + math.max(0, self.DashStartupMean)
    if localMotion and onset > 0 then start = predictPosition(localMotion, onset, true) end
    local path = self:TerrainPathVector(character, localMotion, direction)
    local filter = cacheable and parameters.FilterDescendantsInstances or nil
    if cacheable then
        for _, entry in ipairs(self.TerrainResultCache) do
            if entry.Revision == self.MapRevision and entry.Character == character
                and entry.Start == start and entry.Path == path
                and entry.Strict == strictPhantom
                and entry.Group == parameters.CollisionGroup
                and entry.FilterType == parameters.FilterType
                and entry.Respect == parameters.RespectCanCollide
                and entry.IgnoreWater == parameters.IgnoreWater
                and #entry.Filter == #filter then
                local matches = true
                for index, item in ipairs(filter) do
                    if item ~= entry.Filter[index] then matches = false break end
                end
                if matches then
                    self.TerrainCacheHits += 1
                    return table.unpack(entry.Result, 1, entry.Result.n)
                end
            end
        end
        self.TerrainCacheMisses += 1
    end
    local revision = self.MapRevision
    local result = table.pack(self:EvaluateTerrainRouteUncached(
        character, localRoot, localMotion, direction, delay, parameters, strictPhantom, deadline
    ))
    if cacheable and result[1] == true and revision == self.MapRevision
        and #self.TerrainResultCache < 12 then
        self.TerrainResultCache[#self.TerrainResultCache + 1] = {
            Revision = revision, Character = character, Start = start, Path = path,
            Strict = strictPhantom, Group = parameters.CollisionGroup,
            FilterType = parameters.FilterType, Respect = parameters.RespectCanCollide,
            IgnoreWater = parameters.IgnoreWater, Filter = filter, Result = result,
        }
    end
    return table.unpack(result, 1, result.n)
end


function State:GroupThreatMayReach(threat, rootPosition, travel)
    if (threat.EvaluationStart or 0) > MAX_PREDICTION_TIME then return false end
    local motion, projectile = threat.AttackerMotion, threat.PhysicalProjectile
    local position = projectile and projectile.Position or motion and motion.Position
    if not position or not rootPosition then return true end
    local horizon = math.min(MAX_PREDICTION_TIME, math.max(0, threat.EvaluationEnd or 0.5))
    local velocity = projectile and projectile.Velocity or motion and motion.Velocity or ZERO
    local acceleration = motion and motion.Acceleration or ZERO
    local profile = threat.Profile or {}
    local reach = (profile.Range or 0) + (profile.Radius or 0)
        + (travel or 0) + BODY_RADIUS + math.max(2, threat.Uncertainty or 0)
        + velocity.Magnitude * horizon + 0.5 * acceleration.Magnitude * horizon * horizon
    return (position - rootPosition).Magnitude <= reach
end

function State:GetDirectionThreatPool(primary, now, rootPosition, travel, limit)
    limit = math.clamp(limit or 12, 1, 32)
    local candidates, included = {}, {}
    local complete = true
    local freshness = math.max(0.025, 2 * self.FrameMean)
    local function consider(threat)
        if not threat or included[threat] or not threat.Profile then return end
        included[threat] = true
        if threat ~= primary and (threat.ExpiresAt or 0) <= now then return end
        if threat.Character == LocalPlayer.Character then return end
        if threat.AuditCancelled and not threat.RangedReleased then return end
        local first = threat.EvaluationStart
        local last = threat.EvaluationEnd
        if threat ~= primary and type(first) == "number" and first > MAX_PREDICTION_TIME then return end
        local motion = threat.AttackerMotion
        local projectile = threat.PhysicalProjectile
        if threat ~= primary and not self:GroupThreatMayReach(threat, rootPosition, travel) then return end
        if not threat.LastEvaluatedAt or now - threat.LastEvaluatedAt > freshness
            or type(first) ~= "number" or type(last) ~= "number"
            or not (projectile or motion) then complete = false end
        candidates[#candidates + 1] = threat
    end
    consider(primary)
    for _, threat in ipairs(self.Pending) do consider(threat) end
    table.sort(candidates, function(a,b)
        if a == primary then return b ~= primary end
        if b == primary then return false end
        local first = a.Deadline or math.huge
        local second = b.Deadline or math.huge
        if first ~= second then return first < second end
        return (a.EvaluationStart or math.huge) < (b.EvaluationStart or math.huge)
    end)
    local selected, sources, picked = {}, {}, {}
    local sourceCount = 0
    -- Give each attacker (and each independent projectile) a first slot.
    for _, threat in ipairs(candidates) do
        local source = threat.PhysicalProjectile or threat.Character or threat
        if not sources[source] then
            sources[source] = true
            sourceCount += 1
            if #selected < limit then selected[#selected+1] = threat; picked[threat] = true end
        end
    end
    for _, threat in ipairs(candidates) do
        if #selected >= limit then break end
        if not picked[threat] then selected[#selected+1] = threat; picked[threat] = true end
    end
    complete = complete and #selected == #candidates
    self.LastGroupThreatCount, self.LastGroupSourceCount = #candidates, sourceCount
    self.LastGroupCoverageComplete = complete
    return selected, complete, #candidates
end

function State:SnapshotGroupThreats(threats)
    local result = {}
    for _, threat in ipairs(threats) do
        result[#result+1] = { Threat = threat, EvaluatedAt = threat.LastEvaluatedAt }
    end
    return result
end

function State:GroupPlanMatches(plan, pool, complete)
    if not complete or not plan or not plan.GroupCoverageComplete
        or not plan.GroupThreats or #plan.GroupThreats ~= #pool then return false end
    for _, threat in ipairs(pool) do
        local found = false
        for _, saved in ipairs(plan.GroupThreats) do
            if saved.Threat == threat and saved.EvaluatedAt == threat.LastEvaluatedAt then found = true; break end
        end
        if not found then return false end
    end
    return true
end

function State:GroupPlanBetter(candidate, best)
    if not best then return true end
    local complete = candidate.TerrainSafe == true and candidate.EnvelopeComplete == true
    local oldComplete = best.TerrainSafe == true and best.EnvelopeComplete == true
    if complete ~= oldComplete then return complete end
    local hits, oldHits = candidate.HitThreats or math.huge, best.HitThreats or math.huge
    if hits ~= oldHits then return hits < oldHits end
    if hits > 0 and candidate.EarliestHit ~= best.EarliestHit then
        return (candidate.EarliestHit or 0) > (best.EarliestHit or 0)
    end
    if candidate.WorstClearance ~= best.WorstClearance then
        return (candidate.WorstClearance or -math.huge) > (best.WorstClearance or -math.huge)
    end
    return (candidate.Score or -math.huge) > (best.Score or -math.huge)
end

function State:BoundedGroupSampleTimes(values, maximum, critical)
    table.sort(values)
    local unique = {}
    for _, time in ipairs(values) do
        if #unique == 0 or time - unique[#unique] > 0.0005 then unique[#unique+1] = time end
    end
    if #unique <= maximum then return unique end
    local selected, indices = {}, {}
    local function add(index)
        if index and not indices[index] and #selected < maximum then
            indices[index] = true; selected[#selected+1] = unique[index]
        end
    end
    add(1); add(#unique)
    for _, time in ipairs(critical or {}) do
        if type(time) == "number" then
            for index, sample in ipairs(unique) do if math.abs(time-sample) <= 0.0005 then add(index); break end end
        end
    end
    for index=1,maximum do add(math.floor(1+(#unique-1)*(index-1)/math.max(1,maximum-1)+0.5)) end
    for index=1,#unique do add(index) end
    table.sort(selected)
    return selected
end

local function collectDirectionThreats(primary, character, root)
    character = character or LocalPlayer.Character
    root = root or character and character:FindFirstChild("HumanoidRootPart")
    local travel = character and getDashDistance(character, 0.5, true) or 0
    return State:GetDirectionThreatPool(primary, os.clock(), root and root.Position, travel, MAX_DIRECTION_THREATS)
end

local function chooseDodgeDirectionLegacy(primary, now, character, humanoid, localRoot)
    local camera = workspace.CurrentCamera
    local cameraLook = camera and horizontalUnit(camera.CFrame.LookVector)
        or horizontalUnit(localRoot.CFrame.LookVector)
    local cameraRight = cameraLook:Cross(Vector3.new(0, 1, 0)).Unit
    local movementDirection = humanoid.MoveDirection
    local maximumTravel = getDashDistance(character, 0.5)
    local threats = collectDirectionThreats(primary, character, localRoot)
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
    local threats = collectDirectionThreats(primary, character, localRoot)
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
    local hbSpec = State:GetHBProfile(threat)
    if hbSpec then
        local offset, pathPadding, weight, name = reachableHypothesisAt(threat, timeAhead, hypothesisIndex)
        local frame, size = State:HBBoxAt(threat, hbSpec, timeAhead, offset)
        local clearance = frame and State:HBBodyClearance(frame, size, body,
            uncertainty + (pathPadding or 0)) or math.huge
        return nil, nil, nil, clearance, weight, name
    end
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

function State:RefineThreatInterval(threat,hypothesis,direction,travel,delay,a,b,bodyA,bodyB,clearA,clearB,bodyAt,deadline,remaining,depth)
    depth=depth or 0
    local gap=b-a
    local velocity=threat.PhysicalProjectile and threat.PhysicalProjectile.Velocity
        or threat.AttackerMotion and threat.AttackerMotion.Velocity or ZERO
    local rate=velocity.Magnitude+(bodyB-bodyA).Magnitude/math.max(gap,.001)
    local close=math.min(clearA,clearB) < math.max(2,rate*gap*.5)
    if not self.EnableAdaptiveSampling or depth>=2 or gap<.012 or not close
        or clearA<=0 or clearB<=0 then return false,nil,math.min(clearA,clearB),0,true end
    if remaining<1 or os.clock()>=deadline then return false,nil,math.min(clearA,clearB),0,false end
    local middle=(a+b)*.5
    local body=bodyAt(direction,travel,delay,middle)
    local _,_,_,clearance=mpcThreatGeometryAt(threat,middle,body,hypothesis)
    local hit=clearance<=0
    local earliest=hit and middle or nil
    local worst=math.min(clearA,clearB,clearance)
    local tests=1
    self.AdaptiveSamples+=1
    if hit then self.AdaptiveHits+=1 end
    for side=1,2 do
        local first,last=side==1 and a or middle,side==1 and middle or b
        local firstBody,lastBody=side==1 and bodyA or body,side==1 and body or bodyB
        local firstClear,lastClear=side==1 and clearA or clearance,side==1 and clearance or clearB
        local collided,at,value,used,complete=self:RefineThreatInterval(threat,hypothesis,direction,travel,delay,
            first,last,firstBody,lastBody,firstClear,lastClear,bodyAt,deadline,remaining-tests,depth+1)
        tests+=used;worst=math.min(worst,value)
        if collided then hit=true;earliest=math.min(earliest or math.huge,at) end
        if not complete then return hit,earliest,worst,tests,false end
    end
    return hit,earliest,worst,tests,true
end

function State:FollowupTerrainSafe(character,point,path,parameters,strict,deadline)
    if os.clock()>=deadline then return false,false end
    local role,_,complete=self:SweptMapRoleCollision(point,path,deadline)
    if not complete then return false,false end
    if role then return false,true end
    local limited,obstacle=self:LimitTerrainPath(point,path,parameters)
    if obstacle or limited.Magnitude+.1<path.Magnitude then return false,true end
    local model=self:GetNativeDashModel(character)
    if strict and not self:NativeBurstPathClear(character,point,path,model) then return false,true end
    local safe,reason=self:GroundPathSafe(point,path,parameters,strict,deadline)
    return safe,not self:IsTerrainCheckIncomplete(reason)
end

function State:EvaluateFollowup(candidate,threats,character,humanoid,localMotion,bodyAt,parameters,deadline,remaining)
    local result={Complete=false,Options=0,Tests=0,Mode="Walking corridor"}
    if not self.EnableFollowupPlanning or not candidate.Safe or remaining<1 or os.clock()>=deadline then return result end
    local model=self:GetNativeDashModel(character)
    local second=false
    if model.Mode=="Phantom" then
        local ready=self:GetPhantomCharges(character,os.clock())
        second=ready>=2
    end
    result.Mode=second and "Potential second Phantom charge" or "Walking corridor"
    local onset=(candidate.Delay or 0)+math.max(0,self.DashStartupMean)
    local settle=second and math.max(self.PhantomSettleInterval,self.FlingGuardWindow) or model.Duration
    local start=onset+math.max(model.Duration,settle)
    local finish=math.min(MAX_PREDICTION_TIME,start+.2)
    if finish<=start then return result end
    local point=bodyAt(candidate.Direction,candidate.Travel or 0,candidate.Delay or 0,start)
    local walk=math.clamp(humanoid.WalkSpeed or 14,0,28)
    local distance=second and self:TerrainDashDistance(character,.5) or walk*(finish-start)
    local look=candidate.CameraLook
    for _,code in ipairs({"Forward","Right","Backwards","Left"}) do
        if os.clock()>=deadline then return result end
        local direction=self:ControllerDirectionVector(code,look)
        local supported,complete=self:FollowupTerrainSafe(character,point,direction*distance,parameters,second,deadline)
        if not complete then return result end
        if supported then
            local safe=true
            for _,threat in ipairs(threats) do
                local first=math.max(start,threat.EvaluationStart or 0)
                local last=math.min(finish,threat.EvaluationEnd or finish)
                if first<=last then
                    for sample=0,2 do
                        if result.Tests>=remaining or os.clock()>=deadline then return result end
                        local time=first+(last-first)*sample*.5
                        local travel=second and getDashDistance(character,time-start) or walk*(time-start)
                        local body=point+direction*travel
                        local _,_,_,clearance=mpcThreatGeometryAt(threat,time,body,1)
                        result.Tests+=1
                        if clearance<=0 then safe=false;break end
                    end
                end
                if not safe then break end
            end
            if safe then result.Options+=1 end
        end
    end
    result.Complete=true
    return result
end

local function chooseDodgePlan(primary, now, character, humanoid, localRoot, fastMode)
    local reactionRequestAt = State:ReactionReadyAt(primary)
    if not reactionRequestAt then
        return nil
    end
    reactionRequestAt = math.max(now, reactionRequestAt)
    local solverStarted = os.clock()
    State.MpcSolveCount += 1
    State.LastMpcBudgetReason = "None"
    local dynamicBudget = math.clamp(
        State.FrameMean * 0.18,
        0.0018,
        0.0032
    )
    -- Threat evaluation can exhaust the frame slice before this call. Give
    -- the action solver a bounded reserve rather than repeating a zero-time
    -- incomplete group decision forever. Terrain retains its existing cap.
    local solverDeadline = State:ActionPlanningDeadline(solverStarted, dynamicBudget)
    local availableSolverTime = math.max(0, solverDeadline - solverStarted)
    local terrainReserve = availableSolverTime * State.MpcTerrainBudgetFraction
    local coarseDeadline = solverDeadline - terrainReserve
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
    local threats, groupComplete = collectDirectionThreats(primary, character, localRoot)
    local groupStamps = State:SnapshotGroupThreats(threats)
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

    -- Optimize direction at the fixed reaction time. Never round the wait
    -- down, shorten it for an emergency, or add a later activation candidate.
    local reactionDelay = math.max(0, reactionRequestAt - now)
    local delays = { reactionDelay }
    State.LastMpcDelayCandidates = #delays
    State.LastMpcLatestDelay = reactionDelay

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
        return State:BoundedGroupSampleTimes(values, coarse and 3 or MAX_MPC_SAMPLES, {
            threat.ContactIn or first, threat.ImpactEarliest or first,
            threat.ImpactLatest or last, onset,
        })
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
    local coarseBudgetStopped = false
    local minimumCoarseControls = State.MinimumMpcCoarseControls
    -- Delay-major ordering evaluates the zero-delay cardinal set first.  If
    -- the inherited frame budget is already exhausted, the bounded minimum
    -- still covers distinct directions instead of four delays of Forward.
    for _, delay in ipairs(delays) do
        for _, directionCandidate in ipairs(directions) do
            if #controls >= minimumCoarseControls and (
                tests >= MAX_MPC_TESTS
                or os.clock() >= coarseDeadline
            ) then
                coarseBudgetStopped = true
                State.LastMpcBudgetReason = tests >= MAX_MPC_TESTS
                    and "Coarse test ceiling" or "Terrain time reserve"
                break
            end
            local minimumClearance = math.huge
            local hits = 0
            for threatIndex = 1, #threats do
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
            local comboTailClearance = math.huge
            local comboTail = primary.Profile and primary.Profile.ComboTail
            local attackerMotion = primary.AttackerMotion
            if comboTail and attackerMotion then
                for tailIndex = 1, math.min(2, #comboTail) do
                    local tail = comboTail[tailIndex]
                    local sampleTime = math.min(
                        State.ComboTailHorizon,
                        math.max(0, primary.ContactIn or 0)
                            + (tail.Offset or 0)
                    )
                    local body = bodyAt(
                        directionCandidate.Direction,
                        maximumTravel,
                        delay,
                        sampleTime
                    )
                    local predictedAttacker = predictPosition(
                        attackerMotion,
                        sampleTime,
                        true
                    )
                    local currentAttacker = attackerMotion.Position
                        or predictedAttacker
                    local predictedDelta = predictedAttacker - body
                    local currentDelta = currentAttacker - body
                    local separation = math.min(
                        Vector3.new(
                            predictedDelta.X,
                            0,
                            predictedDelta.Z
                        ).Magnitude,
                        Vector3.new(
                            currentDelta.X,
                            0,
                            currentDelta.Z
                        ).Magnitude
                    )
                    local uncertaintyPad = math.min(
                        9,
                        2 + 12 * sampleTime * sampleTime
                    )
                    local clearance = separation - (
                        (tail.Reach or primary.Profile.Range or 10)
                        + BODY_RADIUS
                        + math.min(primary.Uncertainty or 0, 2)
                        + uncertaintyPad
                    )
                    comboTailClearance = math.min(
                        comboTailClearance,
                        clearance
                    )
                end
            end
            controls[#controls + 1] = {
                Name = directionCandidate.Name,
                Direction = directionCandidate.Direction,
                ControllerDirection = directionCandidate.ControllerDirection,
                Delay = delay,
                CoarseHits = hits,
                CoarseClearance = minimumClearance,
                CoarseTailClearance = comboTailClearance,
                CoarseScore = -hits * 100000
                    + math.min(minimumClearance, 50) * 100
                    + (comboTailClearance < math.huge
                        and math.clamp(comboTailClearance, -30, 30) * 1000
                        or 0)
                    + delay,
            }
        end
        if coarseBudgetStopped then
            break
        end
    end
    table.sort(controls, function(first, secondControl)
        return first.CoarseScore > secondControl.CoarseScore
    end)
    local parameters = State:BuildTerrainParameters(character)
    local terrainRouteCache = {}
    local terrainHeadingCache = {}
    local terrainHeadingsChecked = 0
    -- Terrain must receive usable time even when prediction consumed its
    -- shared deadline. This reserve is bounded across all cardinal routes.
    local terrainStarted = os.clock()
    local terrainDeadline = terrainStarted + State.TerrainPlanningBudget
    local maximumTerrainHeadings = fastMode
        and State.MaxFastMpcTerrainHeadings
        or State.MaxMpcTerrainHeadings
    local firstControlByHeading = {}
    for _, control in ipairs(controls) do
        local existing = firstControlByHeading[control.ControllerDirection]
        if not existing or (control.Delay or 0) < (existing.Delay or 0) then
            firstControlByHeading[control.ControllerDirection] = control
        end
    end
    local headingOrder = {}
    local headingSeen = {}
    for _, candidate in ipairs(controls) do
        local heading = candidate.ControllerDirection
        if not headingSeen[heading] then
            headingSeen[heading] = true
            headingOrder[#headingOrder + 1] = heading
        end
    end
    for _, controllerDirection in ipairs(headingOrder) do
        local control = firstControlByHeading[controllerDirection]
        if control and terrainHeadingsChecked < maximumTerrainHeadings then
            local delayKey = math.floor((control.Delay or 0) * 1000 + 0.5)
            local routeKey = controllerDirection .. ":" .. tostring(delayKey)
                .. ":" .. tostring(State.MapRevision)
            local routeDeadline = math.min(
                terrainDeadline, os.clock() + State.TerrainRouteBudget
            )
            local terrainSafe, terrainReason, terrainSupports, limitedPath =
                State:EvaluateTerrainRoute(
                    character,
                    localRoot,
                    localMotion,
                    control.Direction,
                    control.Delay,
                    parameters,
                    phantomStep,
                    routeDeadline
                )
            local terrain = {
                Safe = terrainSafe,
                Reason = terrainReason,
                Supports = terrainSupports,
                PathMagnitude = limitedPath and limitedPath.Magnitude or 0,
                Delay = control.Delay,
            }
            terrainRouteCache[routeKey] = terrain
            terrainHeadingCache[controllerDirection] = terrain
            terrainHeadingsChecked += 1
        end
    end
    -- Preserve only the solver time that remained before terrain validation;
    -- terrain cannot renew an already exhausted prediction budget.
    solverDeadline += math.min(
        os.clock() - terrainStarted, State.TerrainPlanningBudget
    )
    for _, control in ipairs(controls) do
        local terrain = terrainHeadingCache[control.ControllerDirection]
            or {
                Safe = false,
                Reason = "Cardinal terrain unavailable",
                Supports = 0,
            }
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
    local safeAlternatives={}
    local robustControls = {}
    local robustSelected = {}
    local robustLimit = math.min(
        State.MaxMpcRobustControls,
        MAX_MPC_SHORTLIST,
        #controls
    )
    -- Start with the best terrain-safe control, then force one different
    -- native direction before filling by score.  This avoids spending the
    -- whole robust budget on several delays for the same cardinal dash.
    for _, control in ipairs(controls) do
        if control.CoarseTerrainSafe == true then
            robustControls[1] = control
            robustSelected[control] = true
            break
        end
    end
    if not robustControls[1] and controls[1] then
        robustControls[1] = controls[1]
        robustSelected[controls[1]] = true
    end
    if robustControls[1] and #robustControls < robustLimit then
        for _, control in ipairs(controls) do
            if not robustSelected[control]
                and control.CoarseTerrainSafe == true
                and control.ControllerDirection
                    ~= robustControls[1].ControllerDirection then
                robustControls[#robustControls + 1] = control
                robustSelected[control] = true
                break
            end
        end
    end
    for _, control in ipairs(controls) do
        if #robustControls >= robustLimit then
            break
        end
        if not robustSelected[control]
            and control.CoarseTerrainSafe == true then
            robustControls[#robustControls + 1] = control
            robustSelected[control] = true
        end
    end
    local robustCount = #robustControls
    local completedRobustCandidates = 0
    local budgetStopped = coarseBudgetStopped
    local lastCandidateTests = 0
    local lastCandidateSeconds = 0
    for controlIndex = 1, robustCount do
        if controlIndex > 1 then
            local remainingTests = MAX_MPC_TESTS - tests
            local remainingSeconds = solverDeadline - os.clock()
            if remainingTests < math.max(1, lastCandidateTests)
                or remainingSeconds
                    < math.max(0.00015, lastCandidateSeconds * 1.2) then
                budgetStopped = true
                State.LastMpcBudgetReason = remainingTests
                        < math.max(1, lastCandidateTests)
                    and "Test reserve" or "Time reserve"
                break
            end
        end
        local control = robustControls[controlIndex]
        local candidateStarted = os.clock()
        local candidateTestsBefore = tests
        local direction = control.Direction
        local delay = control.Delay
        local delayKey = math.floor((delay or 0) * 1000 + 0.5)
        local terrainKey = control.ControllerDirection .. ":"
            .. tostring(delayKey) .. ":" .. tostring(State.MapRevision)
        local cachedTerrain = terrainRouteCache[terrainKey]
        if not cachedTerrain then
            local terrainSafe, terrainReason, terrainSupports, limitedPath =
                State:EvaluateTerrainRoute(
                    character,
                    localRoot,
                    localMotion,
                    direction,
                    delay,
                    parameters,
                    phantomStep,
                    math.min(terrainDeadline, os.clock() + State.TerrainRouteBudget)
                )
            cachedTerrain = {
                Safe = terrainSafe,
                Reason = terrainReason,
                Supports = terrainSupports,
                PathMagnitude = limitedPath and limitedPath.Magnitude or 0,
                Delay = delay,
            }
            terrainRouteCache[terrainKey] = cachedTerrain
        end
        -- A delayed request starts from the predicted onset pose, not the
        -- player's current pose.  This prevents walking toward a ledge while
        -- a stale current-position terrain result remains marked safe.
        local travel = math.min(
            maximumTravel,
            cachedTerrain and cachedTerrain.PathMagnitude or 0
        )
        local floorSafe = cachedTerrain and cachedTerrain.Safe
        local terrainReason = cachedTerrain and cachedTerrain.Reason
        local terrainSupports = cachedTerrain and cachedTerrain.Supports

        local hitScenarios = 0
        local hitThreats = 0
        local earliestHit = math.huge
        local worstClearance = math.huge
        local aggregateRisk = 0
        local tailRisk = 0
        if control.CoarseTailClearance
            and control.CoarseTailClearance < math.huge then
            tailRisk = math.max(
                0,
                -control.CoarseTailClearance * 4
            )
        end
        local budgetExpired = false
        local nextBudgetCheck = tests
            + (os.clock() >= solverDeadline and 0 or 8)
        for _, threat in ipairs(threats) do
            local threatHit = false
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
                local previousClearance
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
                    if previousTime and not scenarioHit then
                        local refined,at,value,used,complete=State:RefineThreatInterval(
                            threat,hypothesisIndex,direction,travel,delay,previousTime,sampleTime,
                            previousBody,body,previousClearance,clearance,bodyAt,solverDeadline,MAX_MPC_TESTS-tests)
                        tests+=used
                        scenarioClearance=math.min(scenarioClearance,value)
                        if refined then scenarioHit=true;earliestHit=math.min(earliestHit,at) end
                        if not complete then budgetExpired=true;break end
                    end
                    previousClearance=clearance
                    previousTime = sampleTime
                    previousBody = body
                    previousBase = base
                    previousTip = tip
                    previousRadius = radius
                    if tests >= nextBudgetCheck then
                        nextBudgetCheck = tests + 8
                        if tests >= MAX_MPC_TESTS
                            or os.clock() >= solverDeadline then
                            budgetExpired = true
                            break
                        end
                    end
                end
                if scenarioHit then
                    hitScenarios += 1
                    threatHit = true
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
            if threatHit then hitThreats += 1 end
            if budgetExpired then
                break
            end
        end
        if budgetExpired then
            budgetStopped = true
            State.LastMpcBudgetReason = tests >= MAX_MPC_TESTS
                and "Test ceiling" or "Time ceiling"
            State.LastEnvelopeComplete = false
            tailRisk = math.max(tailRisk, 1000)
        else
            completedRobustCandidates += 1
            lastCandidateTests = math.max(1, tests - candidateTestsBefore)
            lastCandidateSeconds = math.max(
                0.000001,
                os.clock() - candidateStarted
            )
        end
        if worstClearance == math.huge then
            worstClearance = control.CoarseClearance
        end
        local movementAlignment = movementDirection.Magnitude > 0.1
            and movementDirection.Unit:Dot(direction) or 0
        local completedEvaluation = not budgetExpired and groupComplete
        local score = (floorSafe and completedEvaluation and 1 or 0)
                * 1000000000
            - hitScenarios * 10000000
            + (earliestHit == math.huge and MAX_PREDICTION_TIME
                or earliestHit) * 100000
            + math.min(worstClearance, 50) * 1000
            - aggregateRisk * 20
            - tailRisk * 35
            + (control.CoarseTailClearance
                    and control.CoarseTailClearance < math.huge
                and math.clamp(
                    control.CoarseTailClearance,
                    -30,
                    30
                ) * 2500
                or 0)
            + travel * 2
            + movementAlignment * 3
            + delay
        if travel < 4 then
            score -= 2000000
        end
        local safe = completedEvaluation and floorSafe
            and hitScenarios == 0 and travel >= 4
        do
            local confidence = math.clamp(
                0.45
                    + 0.3 * math.clamp(worstClearance / 10, 0, 1)
                    + 0.2 * (primary.Confidence or 0.75)
                    - (budgetExpired and 0.15 or 0),
                0.2,
                0.99
            )
            local candidate = {
                Generation = State.Generation,
                MapRevision = State.MapRevision,
                Threat = primary,
                ReactionConfirmedAt = primary.FirstConfirmedAt,
                CameraLook = cameraLook,
                PlannedRootPosition = localRoot.Position,
                Name = control.Name,
                Direction = direction,
                ControllerDirection = control.ControllerDirection,
                Delay = delay,
                RequestAt = reactionRequestAt,
                Deadline = primary.Deadline,
                Score = score,
                Safe = safe,
                Travel = travel,
                TerrainSafe = floorSafe,
                TerrainReason = terrainReason,
                TerrainSupports = terrainSupports,
                Confidence = confidence,
                WorstClearance = worstClearance,
                TailRisk = tailRisk,
                EnvelopeComplete = completedEvaluation,
                HitThreats = hitThreats,
                EarliestHit = earliestHit,
                GroupThreats = groupStamps,
                GroupCoverageComplete = groupComplete,
                FastMode = fastMode == true,
                Tests = tests,
            }
            if candidate.Safe then safeAlternatives[#safeAlternatives+1]=candidate end
            if #threats > 1 and State:GroupPlanBetter(candidate, best)
                or #threats <= 1 and (not best or score > best.Score) then best = candidate end
        end
        if budgetExpired then
            break
        end
    end

    State.LastFollowupMode="Not evaluated"
    State.LastFollowupOptions=0
    if State.EnableFollowupPlanning and best and best.Safe and #safeAlternatives>=2 then
        table.sort(safeAlternatives,function(a,b) return State:GroupPlanBetter(a,b) end)
        local alternatives={best}
        for _,candidate in ipairs(safeAlternatives) do
            if candidate~=best then alternatives[2]=candidate;break end
        end
        local deadline=math.min(solverDeadline,os.clock()+.0012)
        for index=1,#alternatives do
            local candidate=alternatives[index]
            candidate.Followup=State:EvaluateFollowup(candidate,threats,character,humanoid,localMotion,bodyAt,parameters,deadline,MAX_MPC_TESTS-tests)
            tests+=candidate.Followup.Tests
            if candidate.Followup.Complete then State.FollowupCompleted+=1 else State.FollowupDeferred+=1 end
        end
        local preference=alternatives[2] and State:PreferFollowup(alternatives[2],best)
        if preference==true then best=alternatives[2] end
        if best.Followup then
            State.LastFollowupMode=best.Followup.Complete and best.Followup.Mode or "Budget deferred"
            State.LastFollowupOptions=best.Followup.Complete and best.Followup.Options or 0
        end
    end
    State.LastMpcCompletedCandidates = completedRobustCandidates
    if budgetStopped then
        State.MpcBudgetAborts += 1
        if completedRobustCandidates == 0 then
            State.EnvelopeBudgetFallbacks += 1
            State.MpcCoarseFallbacks += 1
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

function State:PreviewGroupDodge(primary, character, humanoid, root, now)
    -- Runs the planner only: never emits input, moves a character, or requests a dash.
    return chooseDodgePlan(primary, now or os.clock(), character, humanoid, root, true)
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

-- Info's release payload has no direction field: the native controller
-- samples Humanoid.MoveDirection when shared.controllerpressed is true.
-- Set that direction directly, then dispatch without a key pulse or wait.
function State:ReleaseNativeDash(info, humanoid, direction)
    humanoid:Move(direction, false)
    local releaseAt = os.clock()
    info:Fire({ DashingReleased = true })
    return releaseAt
end

local function nativeDodge(threat, suppliedPlan)
    if threat.Character and threat.Character == LocalPlayer.Character then
        State.LastBlockReason = "Own attack ignored"
        return false
    end
    if State.SuppressActions or not State.Enabled
        or State.Initializing or State.AttemptPending then
        State.LastBlockReason = State.AttemptPending
            and "Awaiting dash acknowledgement" or "Inactive"
        return false
    end
    local reactionReadyAt = State:ReactionReadyAt(threat)
    if not reactionReadyAt then
        State.LastBlockReason = "Threat unconfirmed"
        return false, "reaction_unconfirmed"
    end
    if os.clock() < reactionReadyAt then
        State.LastBlockReason = "Reaction wait"
        return false, "reaction_wait"
    end
    if threat.Profile and threat.Profile.Learned
        and (threat.Confidence or 0) < 0.82
        and not threat.PhysicalProjectile
        and not threat.Emergency then
        State.LastBlockReason = "Learned threat confidence"
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
    local dashReady, dashReason, dashRemaining,
        dashCharges, dashMaximum, dashSource =
        nativeDashAvailable(character, humanoid)
    if not dashReady then
        State:RecordDashAvailabilityBlock(
            threat,
            os.clock(),
            dashReason,
            dashRemaining,
            dashCharges,
            dashMaximum,
            dashSource
        )
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
    if State:TerrainRetryBlocked(threat, now) then
        State.LastBlockReason = "Terrain route retry"
        return false, "terrain_retry"
    end
    local function rejectTerrain(reason)
        State:RecordAuditBlock(threat, reason, now)
        if reason == "Ground coverage budget" then
            threat.TerrainBlockedUntil = now + State.TerrainCoverageRetryInterval
            threat.TerrainCoveragePosition = localRoot.Position
            threat.TerrainCoverageRevision = State.MapRevision
            reason = string.format(
                "Ground coverage budget (%.2f studs; limit %.2f; %d segments)",
                State.LastGroundTravel, State.LastGroundCoverageLimit,
                State.LastGroundSegments
            )
        end
        if State:IsTerrainCheckIncomplete(reason)
            or string.sub(reason or "", 1, 22) == "Ground coverage budget" then
            State.TerrainDeferredChecks += 1
            State.LastTerrainStatus = "Validation pending: " .. tostring(reason)
            State.LastBlockReason = State.LastTerrainStatus
            State.DodgePlan = nil
            State.NextMpcAt = 0
            return false, "terrain_pending"
        end
        State.TerrainRejectedDodges += 1
        State.LastTerrainStatus = reason or "No safe ground"
        State.LastBlockReason = State.LastTerrainStatus
        State.DodgePlan = nil
        -- Replan on the next prediction opportunity.  A fixed terrain lock
        -- created visible stalls during fast fork rushes after one route was
        -- vetoed, even when another cardinal route was already available.
        threat.TerrainBlockedUntil = now
        State.NextMpcAt = 0
        pushReplay("dodge_ground_rejected", now, {
            Threat = threat.Profile and threat.Profile.Name or "Unknown",
            Reason = State.LastTerrainStatus,
        })
        updateStatus(false)
        return false, "terrain_rejected"
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
    local groupPool, groupComplete, groupCount = collectDirectionThreats(threat, character, localRoot)
    if groupCount > 1 and not State:GroupPlanMatches(plan, groupPool, groupComplete) then plan = nil end
    -- The reaction wait has elapsed. Validate an immediate release rather
    -- than executing a direction evaluated with a remaining future wait.
    if not plan or (plan.Delay or 0) > 0 or plan.Threat ~= threat
        or plan.ReactionConfirmedAt ~= threat.FirstConfirmedAt
        or plan.Generation ~= State.Generation
        or plan.MapRevision ~= State.MapRevision then
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
    if groupCount > 1 then
        if not State:GroupPlanMatches(plan, groupPool, groupComplete)
            or not plan.EnvelopeComplete or not plan.TerrainSafe then
            State.GroupIncompleteBlocks += 1
            State.LastGroupStatus = "Group evaluation incomplete"
            State.LastBlockReason = State.LastGroupStatus
            State.DodgePlan = nil
            State.NextMpcAt = 0
            return false, "group_pending"
        end
        State.LastGroupStatus = plan.Safe and "Group route evaluated" or "Least-risk evaluated route"
    else
        State.LastGroupStatus = "Single threat"
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

    -- Airborne ordinary dashes still need a supported predicted landing.
    -- Skipping this check was the remaining way to dash off circular ledges.
    local parameters = State:BuildTerrainParameters(character)
    local groundSafe, groundReason, groundSupports =
        State:EvaluateTerrainRoute(
            character,
            localRoot,
            State.LocalMotion,
            direction,
            0,
            parameters,
            phantomStep,
            os.clock() + State.TerrainPreflightBudget,
            true -- Never reuse planning results for an actual dash release.
        )
    if not groundSafe then
        return rejectTerrain(groundReason)
    end
    State.LastTerrainStatus = string.format(
        "Supported (%d rails)",
        groundSupports or 0
    )
    local requestBudgetToken = reserveRequestSlot(now)
    if not requestBudgetToken then
        return false
    end
    local reactionStartedAt = threat.FirstConfirmedAt
    local requestAt = os.clock()
    local originalMovement = humanoid.MoveDirection
    local previousControllerPressed = rawget(shared, "controllerpressed")
    local beforeRecentDash = character:GetAttribute("RecentDash")
    local beforePhantomStacks
    local beforePhantomSource = "Native"
    local beforePhantomReady = 0
    local beforePhantomMaximum = 0
    if phantomStep then
        beforePhantomStacks, beforePhantomSource =
            State:GetPhantomStackCount(character, requestAt)
        beforePhantomReady, beforePhantomMaximum =
            State:PhantomReadyCharges(
                beforePhantomStacks,
                State:PhantomUsesSingleChargeMode()
            )
    end
    local preexistingVelocityMovers = setmetatable({}, { __mode = "k" })
    for _, child in ipairs(localRoot:GetChildren()) do
        if State:IsDashVelocityMover(child) then preexistingVelocityMovers[child] = true end
    end
    local beforeController = State:ResolveDashControllerState(character)
    local burstDash = State:GetNativeDashModel(character).Duration <= 0.05
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
        BaselineVelocity = ZERO,
        BeforeNativeControllerPresent = beforeController ~= nil,
        BeforeNativeDashCD = beforeController and beforeController.DashCD == true or false,
        PreexistingMovers = preexistingVelocityMovers,
        BurstDash = burstDash,
        LeaseToken = leaseToken,
        BeforeRecentDash = beforeRecentDash,
        WasPhantomStep = phantomStep,
        BeforePhantomStacks = beforePhantomStacks,
        BeforePhantomSource = beforePhantomSource,
        BeforePhantomReady = beforePhantomReady,
        BeforePhantomMaximum = beforePhantomMaximum,
        PeakDirectionDot = -1,
        PeakDirectionDistance = 0,
        PeakDirectionSpeed = 0,
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
    State.AttemptPending.Audit = State:BeginDodgeAudit(
        threat, character, localRoot, requestAt, directionName, plan
    )
    State.DodgePlan = nil
    pushReplay("dodge_request", requestAt, {
        Threat = threat.Profile.Name,
        Direction = directionName,
        Delay = plan and plan.Delay or 0,
        Confidence = plan and plan.Confidence or threat.Confidence or 0.75,
        AuditId = State.AttemptPending.Audit.Id,
        Evidence = State.AttemptPending.Audit.Evidence,
        EnvelopeComplete = State.AttemptPending.Audit.EnvelopeComplete,
    })

    -- The controller's normal uncharged Q path enters its release routine
    -- directly. Firing only DashingReleased avoids the hold/charge state and
    -- therefore adds no artificial delay.
    local releaseAt
    local ok, message = xpcall(function()
        rawset(shared, "controllerpressed", true)
        releaseAt = State:ReleaseNativeDash(info, humanoid, direction)
        State.DashReleases += 1
        if phantomStep then
            State.PhantomDashReleases += 1
            local fallbackSpend = State:RecordPhantomFallbackSpend(
                character,
                beforePhantomSource,
                os.clock(),
                beforeRecentDash
            )
            if State.AttemptPending then
                State.AttemptPending.FallbackSpendRecorded = fallbackSpend
            end
            State:GetPhantomCharges(character, os.clock())
        end
    end, debug.traceback)
    if not ok then
        if State.AttemptPending and State.AttemptPending.Telemetry then
            State.AttemptPending.Telemetry.Rejected = true
        end
        if State.AttemptPending then
            State:RollbackPhantomFallbackSpend(
                character,
                State.AttemptPending.FallbackSpendRecorded,
                State.AttemptPending.BeforeRecentDash
            )
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
    if burstDash then
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

function State:InsertThreatByDeadline(top, threat)
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

local function insertTopThreat(threat)
    State:InsertThreatByDeadline(State.TopThreats, threat)
end

function State:PerThreatActionBlock(threat, now)
    if not self:ReactionReady(threat, now) then
        return "Reaction wait"
    end
    if State:TerrainRetryBlocked(threat, now) then
        return "Terrain route retry"
    end
    if (threat.RequestCount or 0) >= 2 then
        return "Threat attempt limit"
    end
    if (threat.WireRequestCount or 0) >= 2 then
        return "Threat wire limit"
    end
    if threat.Profile and threat.Profile.Learned
        and (threat.Confidence or 0) < 0.82
        and not threat.PhysicalProjectile
        and not threat.Emergency then
        return "Learned threat confidence"
    end
    return nil
end

-- A threat whose own route is in a retry lock must not monopolize the one
-- native dash decision. The selected secondary still plans against every
-- pending threat, including the blocked primary, so this changes scheduling
-- without weakening terrain safety or spamming the dash controller.
function State:SelectActionThreat(threats, now)
    local primary = threats and threats[1]
    if not primary then
        return nil, 0, nil
    end
    local primaryBlock = self:PerThreatActionBlock(primary, now)
    if not primaryBlock then
        return primary, 1, nil
    end
    for index = 2, #threats do
        local candidate = threats[index]
        if not self:PerThreatActionBlock(candidate, now) then
            return candidate, index, primaryBlock
        end
    end
    return primary, 1, primaryBlock
end

function State:RecordThreatPrioritySkip(primary, selected, index, reason, now)
    if not primary or not selected or index <= 1 then
        return
    end
    local token = primary.TerrainBlockedUntil
        or primary.RequestCount
        or primary.WireRequestCount
        or reason
    if primary.PrioritySkipToken == token then
        return
    end
    primary.PrioritySkipToken = token
    State.ThreatPrioritySkips += 1
    pushReplay("threat_priority_skip", now, {
        Threat = primary.Profile and primary.Profile.Name or "Unknown",
        Selected = selected.Profile and selected.Profile.Name or "Unknown",
        Index = index,
        Reason = reason or "Per-threat block",
    })
end

function State:ScheduledNativeDodge(threat, plan, threats)
    local acted, failure = nativeDodge(threat, plan)
    if not acted then self:RecordDecisionBlock(threat, os.clock()) end
    if acted or (failure ~= "terrain_rejected"
        and failure ~= "terrain_retry") then
        return acted
    end

    -- A second fork contact can be shorter than one rendered frame. Retry an
    -- already-evaluated secondary immediately after a terrain veto instead
    -- of waiting for Heartbeat and letting the blocked primary starve it.
    local retryNow = os.clock()
    local fallback, fallbackIndex, blockReason =
        self:SelectActionThreat(threats, retryNow)
    if not fallback or fallback == threat then
        return false
    end
    self:RecordThreatPrioritySkip(
        threat,
        fallback,
        fallbackIndex,
        blockReason or failure,
        retryNow
    )
    if self:ReactionReady(fallback, retryNow) then
        local fallbackActed = nativeDodge(fallback)
        if not fallbackActed then self:RecordDecisionBlock(fallback, os.clock()) end
        return fallbackActed
    end
    return false
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
        QueueAttack = function(
            targetCharacter,
            track,
            callbackGeneration,
            forceDashRetry
        )
            queueAttack(
                targetCharacter,
                track,
                callbackGeneration,
                forceDashRetry
            )
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
    State.RecentEnemyDashDirections[character] = nil
    State.RecentEnemyDashWalkBridgeUntil[character] = nil
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
    table.clear(State.TerrainResultCache)
    State.FrameBudgetActive = true
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
    State:PruneDeferredDashAttacks(now)
    if State.ProfileRefreshes < 1
        and State.ProfileRefreshAttempts < 4
        and now >= State.NextProfileRefreshAt then
        State.ProfileRefreshAttempts += 1
        if buildProfiles(true) then
            State.ProfileRefreshes += 1
        else
            State.NextProfileRefreshAt = now + 0.5
        end
    end
    local localCharacter, localHumanoid, localRoot = getLocalCharacter()
    -- Track power transitions even with no active threat.  This resets the
    -- fallback RecentDash baseline on unequip/re-equip, so a normal dash from
    -- another power cannot be miscounted as a Phantom charge.
    State:GetPhantomCharges(localCharacter, now)
    State:MonitorDashSafety(now, localCharacter, localRoot)
    if localCharacter and localRoot then
        State.LocalMotion = sampleMotion(State.LocalMotion, localRoot, now)
        sampleCharacters(now, localRoot)
    else
        State.LocalMotion = nil
    end
    sampleProjectiles(now, State.LocalMotion)
    State:SampleDashTelemetry(now)
    State:SampleDodgeAudits(now, localCharacter)
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
    local groupTravel = localCharacter and getDashDistance(localCharacter, 0.5, true) or 0
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
                    and not State:GroupThreatMayReach(threat, localRoot and localRoot.Position, groupTravel)
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
            State.EvaluationOrder[#State.EvaluationOrder + 1] = threat
        elseif threat.ContactIn then
            State.StaleThreatDrops += 1
        end
    end
    table.sort(State.EvaluationOrder, function(first, second)
        return first.Deadline < second.Deadline
    end)
    local earliestThreat = State.TopThreats[1]
    local mostUrgent, actionThreatIndex, primaryBlockReason =
        State:SelectActionThreat(State.EvaluationOrder, decisionNow)
    State:RecordThreatPrioritySkip(
        earliestThreat,
        mostUrgent,
        actionThreatIndex,
        primaryBlockReason,
        decisionNow
    )
    local plan = State.DodgePlan
    if plan and (
        plan.Generation ~= State.Generation
        or plan.MapRevision ~= State.MapRevision
        or not plan.Threat
        or not State.PendingIndex[plan.Threat.Key]
        or plan.Threat ~= mostUrgent
        or plan.ReactionConfirmedAt ~= mostUrgent.FirstConfirmedAt
    ) then
        State.DodgePlan = nil
        plan = nil
    end
    if mostUrgent and localCharacter and localHumanoid and localRoot then
        if State.AttemptPending then
            State.LastBlockReason = "Awaiting dash acknowledgement"
        else
            local dashReady, dashReason, dashRemaining,
                dashCharges, dashMaximum, dashSource =
                nativeDashAvailable(localCharacter, localHumanoid)
            if not dashReady then
            -- Keep collision prediction current, but do not burn the MPC and
            -- terrain budget on an action the native controller cannot take.
                State:RecordDashAvailabilityBlock(
                    mostUrgent,
                    decisionNow,
                    dashReason,
                    dashRemaining,
                    dashCharges,
                    dashMaximum,
                    dashSource
                )
                State.DodgePlan = nil
                plan = nil
            else
                local reactionReadyAt = State:ReactionReadyAt(mostUrgent)
                if reactionReadyAt
                    and reactionReadyAt - decisionNow <= MPC_ARM_WINDOW then
                    local timeToReaction = math.max(0, reactionReadyAt - decisionNow)
                    local fastMode = mostUrgent.Emergency
                        and reactionReadyAt <= decisionNow
                    local replanInterval = timeToReaction <= 0.12
                        and math.max(State.FrameMean, 1 / 120)
                        or MPC_REPLAN_INTERVAL
                    if not plan or decisionNow >= State.NextMpcAt
                        or (reactionReadyAt <= decisionNow and (plan.Delay or 0) > 0)
                        or (fastMode and plan.FastMode ~= true) then
                        State.NextMpcAt = decisionNow + replanInterval
                        State.DodgePlan = chooseDodgePlan(
                            mostUrgent,
                            decisionNow,
                            localCharacter,
                            localHumanoid,
                            localRoot,
                            fastMode
                        )
                        plan = State.DodgePlan
                    end
                    local actNow = os.clock()
                    if State:ReactionReady(mostUrgent, actNow) then
                        State:ScheduledNativeDodge(
                            mostUrgent,
                            plan,
                            State.EvaluationOrder
                        )
                    else
                        State.LastBlockReason = "Reaction wait"
                    end
                else
                    State.DodgePlan = nil
                end
            end
        end
    elseif not mostUrgent then
        State.DodgePlan = nil
        State.LastBlockReason = "None"
    end
    State:ProcessMapAudit(os.clock())
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
    if not valid then
        threat.ContactIn = nil
        threat.Emergency = false
        threat.Deadline = math.huge
        threat.CandidateImpactAt = nil
        threat.LastEvaluatedAt = now
        return
    end
    local actNow = os.clock()
    if allowDodge and valid and threat.ContactIn
        and State:ReactionReady(threat, actNow) then
        nativeDodge(threat)
    end
end

local function dodgeMostUrgentNow(now)
    if State.AttemptPending then
        return
    end
    now = os.clock()
    local freshnessLimit = math.max(0.025, 2 * State.FrameMean)
    local urgentThreats = {}
    for _, threat in ipairs(State.Pending) do
        if threat.ContactIn and threat.LastEvaluatedAt
            and now - threat.LastEvaluatedAt <= freshnessLimit then
            urgentThreats[#urgentThreats + 1] = threat
        end
    end
    table.sort(urgentThreats, function(first, second)
        return first.Deadline < second.Deadline
    end)
    local earliestThreat = urgentThreats[1]
    local mostUrgent, actionThreatIndex, primaryBlockReason =
        State:SelectActionThreat(urgentThreats, now)
    State:RecordThreatPrioritySkip(
        earliestThreat,
        mostUrgent,
        actionThreatIndex,
        primaryBlockReason,
        now
    )
    if mostUrgent and State:ReactionReady(mostUrgent, now) then
        State:ScheduledNativeDodge(mostUrgent, nil, urgentThreats)
    end
end

local function promoteDashAttacks(attackerCharacter, now, dashDirection)
    State.RecentEnemyDashes[attackerCharacter] = now + DASH_LINK_WINDOW
    State.RecentEnemyDashDirections[attackerCharacter] = dashDirection
    State.RecentEnemyDashWalkBridgeUntil[attackerCharacter] =
        now + State.DashRetryWindow
    for _, threat in ipairs(State.Pending) do
        if threat.Character == attackerCharacter then
            -- Preserve the animation's cardinal direction. A bounded bridge
            -- can use strongly aligned ordinary movement while replicated dash
            -- velocity catches up, including side/back dashes toward us.
            threat.DashHintUntil = now + DASH_LINK_WINDOW
            threat.DashDirection = dashDirection
            threat.DashWalkBridgeUntil = now + State.DashRetryWindow
            -- A dash changes motion, not the attack animation's lifetime.
            evaluateImmediately(threat, now, false)
        end
    end

    -- AnimationPlayed callbacks have no guaranteed order. If the attack was
    -- delivered just before its dash, queueAttack may have correctly found it
    -- outside ordinary walking reach. Retry that one bounded candidate now
    -- that the real dash animation exists instead of losing it forever.
    local watcher = State.Watchers[attackerCharacter]
    local deferredAttacks = State:TakeDeferredDashAttacks(watcher, now)
    for _, deferred in ipairs(deferredAttacks) do
        pushReplay("dash_attack_retry", now, {
            Direction = dashDirection or "Unknown",
            Wait = math.max(0, now - deferred.At),
        })
        queueAttack(
            attackerCharacter,
            deferred.Track,
            deferred.Generation,
            deferred
        )
    end
    dodgeMostUrgentNow(now)
end

queueAttack = function(attackerCharacter, track, generation, forceDashRetry)
    if not State.Enabled or generation ~= State.Generation
        or attackerCharacter == LocalPlayer.Character then
        return
    end
    local now = os.clock()
    local lastSeenAt = State.SeenTracks[track]
    if lastSeenAt and now - lastSeenAt < 0.05 and not forceDashRetry then
        return
    end
    State.SeenTracks[track] = now

    local animation = track.Animation
    local id = animation and normalizeAnimationId(animation.AnimationId)
    local playedDashDirection = id and State.DashIds
        and State.DashIds[id]
    if playedDashDirection then
        promoteDashAttacks(attackerCharacter, now, playedDashDirection)
        return
    end

    if not forceDashRetry then
        State.AttackEvents += 1
    end
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
    local confirmedHB = State.ConfirmedHBProfiles[id]
    if confirmedHB and profile.Kind ~= "Ranged" then
        profile = table.clone(profile)
        local scaleValue = Values:FindFirstChild("HitboxMultiplier")
        local scale = scaleValue and tonumber(scaleValue.Value) or 1
        local reach = confirmedHB.CFrameOffset.Position.Magnitude
            + confirmedHB.HitboxSize.Magnitude * math.max(0, scale or 1) * 0.5
            + (confirmedHB.VelocityPrediction and 10 or 0)
        profile.Range = math.max(profile.Range or 0, reach)
        profile.ActiveStart, profile.ActiveEnd = confirmedHB.ActiveStart, confirmedHB.ActiveEnd
    end
    if not forceDashRetry then
        State.RecognizedAttacks += 1
    end

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
    if type(forceDashRetry) == "table" then
        speed = math.max(forceDashRetry.PlaybackSpeed or speed, 0.05)
        timePosition = math.max(
            timePosition,
            (forceDashRetry.TimePosition or 0)
                + math.max(0, now - forceDashRetry.At) * speed
        )
    end
    local perAnimationCalibration = calibrationFor(profile, id)
    if not forceDashRetry then
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
    end
    local effectiveStart, effectiveEnd, effectiveRelease = effectiveTiming(
        profile,
        id
    )
    if confirmedHB then
        effectiveStart, effectiveEnd = confirmedHB.ActiveStart, confirmedHB.ActiveEnd
    end
    if forceDashRetry and not track.IsPlaying then
        local stoppedPhase = math.max(track.TimePosition or 0,
            type(forceDashRetry) == "table" and forceDashRetry.TimePosition or 0)
        local activePhase = profile.Kind == "Ranged" and effectiveRelease or effectiveStart
        if stoppedPhase < activePhase - POST_ACTIVE_TOLERANCE then
            return
        end
    end
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
    local dashDirection = dashHint
        and State.RecentEnemyDashDirections[attackerCharacter] or nil
    local dashWalkBridgeUntil = dashHint
        and State.RecentEnemyDashWalkBridgeUntil[attackerCharacter] or nil
    local dashWalkBridge = dashHint
        and (dashWalkBridgeUntil or 0) >= now
    local baseReach = math.max(
        profile.Range or 0,
        profile.FarReach or 0,
        profile.Radius or 0
    )
    local facingDot = horizontalUnit(
        watcher.Root.CFrame.LookVector,
        targetDirection
    ):Dot(targetDirection)
    local dashAligned = attackerApproachSpeed >= DASH_CONFIRM_MIN_SPEED
        and attackerAlignment >= DASH_CONFIRM_DOT
    local provisionalDashDirection = State:DashDirectionVector(
        attackerCharacter,
        dashDirection,
        watcher.Root.CFrame.LookVector
    )
    local dashDirectionDot = provisionalDashDirection:Dot(targetDirection)
    local horizontalAttackerSpeed = Vector3.new(
        attackerVelocity.X,
        0,
        attackerVelocity.Z
    ).Magnitude
    local walkDash = State:IsWalkDashAligned(
        dashWalkBridge,
        dashDirection,
        horizontalAttackerSpeed,
        dashDirectionDot
    )
    local dashAttack = dashHint
            and (
                dashAligned
                or walkDash
                or distance <= baseReach + BODY_RADIUS + 2
                    and dashDirectionDot >= 0.35
            )
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
    local acquisitionApproachSpeed = dashHint
        and math.max(approachSpeed, 140) or approachSpeed
    local acquisitionAcceleration = dashHint
        and math.max(approachAcceleration, 320) or approachAcceleration
    local acquisitionRange = profile.Kind == "Ranged"
        and profile.Range
        or math.min(
            NEAR_SAMPLE_RANGE,
            baseReach + BODY_RADIUS + QUEUE_MARGIN
                + acquisitionApproachSpeed * activeHorizon
                + 0.5 * acquisitionAcceleration
                    * activeHorizon * activeHorizon
        )
    if distance > acquisitionRange then
        if not forceDashRetry and profile.Kind ~= "Ranged" then
            local possibleDashRange = State:DashCandidateAcquisitionRange(
                baseReach,
                activeHorizon
            )
            if distance <= possibleDashRange then
                State:StoreDeferredDashAttack(watcher, {
                    Track = track,
                    At = now,
                    Generation = generation,
                    TimePosition = timePosition,
                    PlaybackSpeed = speed,
                    WasPlaying = track.IsPlaying == true,
                })
                pushReplay("dash_attack_deferred", now, {
                    Id = id or "",
                    Threat = profile.Name,
                    Distance = distance,
                    Acquisition = acquisitionRange,
                    PossibleDash = possibleDashRange,
                })
            end
        end
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
        DashDirection = dashDirection,
        DashWalkBridgeUntil = dashWalkBridge and dashWalkBridgeUntil or nil,
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
    State:RemoveDeferredDashAttack(watcher, track)
    if not forceDashRetry then State:ObserveAttackAudit(threat) end
    pushReplay("attack_seen", now, {
        Id = id or "",
        Threat = profile.Name,
        Confidence = threat.Confidence,
        Distance = distance,
        DashHint = dashHint and true or false,
        DashDirection = dashDirection or "None",
        DashConfirmed = dashAttack and true or false,
        DashRetry = forceDashRetry and true or false,
    })
    evaluateImmediately(threat, now, false)
    dodgeMostUrgentNow(now)
    updateStatus(false)
end

function State:RunSelfTest()
    local result = {}
    -- These boundary tests deliberately exercise a configured 100 ms wait.
    -- Runtime still defaults to zero; test that independently below.
    local timingProbe = setmetatable({
        FixedReactionMilliseconds = 100,
        FrameMean = 1 / 60,
    }, { __index = self })
    local immediateProbe = setmetatable({ FixedReactionMilliseconds = 0 }, { __index = self })
    result.ZeroReactionRemainsImmediate = immediateProbe:ReactionReady(
        { FirstConfirmedAt = 10 }, 10
    )
    local reactionThreat = { FirstConfirmedAt = 10, LastConfirmedAt = 10 }
    local reactionReadyAt = timingProbe:ReactionReadyAt(reactionThreat)
    result.FixedReactionBoundary = reactionReadyAt == 10.1
        and not timingProbe:ReactionReady(reactionThreat, reactionReadyAt - 0.000001)
        and timingProbe:ReactionReady(reactionThreat, reactionReadyAt)
        and timingProbe:ReactionReady(reactionThreat, reactionReadyAt + 0.02)
    reactionThreat.Emergency = true
    result.EmergencyRespectsReactionWait =
        not timingProbe:ReactionReady(reactionThreat, reactionReadyAt - 0.000001)
        and timingProbe:ReactionReady(reactionThreat, reactionReadyAt)
    result.UnconfirmedReactionBlocked =
        not timingProbe:ReactionReady({}, reactionReadyAt)
    local fusedReaction = { FirstConfirmedAt = 10.02, LastConfirmedAt = 10.02 }
    timingProbe:MergeReactionConfirmation(fusedReaction, reactionThreat, 10.03)
    result.FusedReactionClockPreserved = fusedReaction.FirstConfirmedAt == 10
        and fusedReaction.CountedPrediction == true
        and timingProbe:ReactionReadyAt(fusedReaction) == reactionReadyAt
    local staleFusedReaction = { FirstConfirmedAt = 9, LastConfirmedAt = 9 }
    timingProbe:MergeReactionConfirmation(staleFusedReaction, reactionThreat, 10.03)
    result.StaleFusedReactionClockDiscarded =
        staleFusedReaction.FirstConfirmedAt == reactionThreat.FirstConfirmedAt
        and timingProbe:ReactionReadyAt(staleFusedReaction) == reactionReadyAt
    local expiredFusion = { FirstConfirmedAt = 9, LastConfirmedAt = 9 }
    timingProbe:MergeReactionConfirmation(expiredFusion, {
        FirstConfirmedAt = 9.1, LastConfirmedAt = 9.1,
    }, 10.03)
    result.ExpiredFusionReactionClockCleared = expiredFusion.FirstConfirmedAt == nil
        and not timingProbe:ReactionReady(expiredFusion, 10.03)
    timingProbe:ClearReactionConfirmation(fusedReaction)
    result.CancelledReactionClockCleared = fusedReaction.FirstConfirmedAt == nil
        and fusedReaction.LastConfirmedAt == nil
        and fusedReaction.CountedPrediction == false
        and not timingProbe:ReactionReady(fusedReaction, 20)
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
    result.ForwardDashDirectionBound = State.DashIds
        and State.DashIds["108126144370302"] == "Forward"
    result.WalkDashBridgeBounded = State.DashRetryWindow <= 0.12
    result.ForwardWalkingDashLinked = State:IsWalkDashAligned(
        true,
        "Forward",
        16,
        0.9
    )
    result.SideWalkingDashLinked = State:IsWalkDashAligned(
        true,
        "Right",
        16,
        0.9
    )
    result.BackWalkingDashLinked = State:IsWalkDashAligned(
        true,
        "Backwards",
        16,
        0.9
    )
    result.AwayWalkingDashRejected = not State:IsWalkDashAligned(
        true,
        "Left",
        16,
        -0.9
    )
    result.UnhintedWalkingRejected = not State:IsWalkDashAligned(
        false,
        "Forward",
        16,
        0.9
    )
    result.SlowWalkingDashRejected = not State:IsWalkDashAligned(
        true,
        "Forward",
        State.DashWalkConfirmMinSpeed - 0.1,
        0.9
    )
    result.MisdirectedWalkingDashRejected = not State:IsWalkDashAligned(
        true,
        "Forward",
        16,
        State.DashForwardFacingDot - 0.01
    )
    local dashFallback = Vector3.new(0, 0, -1)
    result.CardinalDashVectors = State:DashDirectionVector(
            nil,
            "Backwards",
            dashFallback
        ):Dot(-dashFallback) > 0.999
        and State:DashDirectionVector(
            nil,
            "Right",
            dashFallback
        ):Dot(Vector3.new(1, 0, 0)) > 0.999
        and State:DashDirectionVector(
            nil,
            "Left",
            dashFallback
        ):Dot(Vector3.new(-1, 0, 0)) > 0.999
    local retryProbe = {
        Track = true,
        At = 10,
        Generation = State.Generation,
    }
    result.DashRetryFresh = State:IsDashRetryFresh(retryProbe, 10.06)
    result.DashRetryExpires = not State:IsDashRetryFresh(
        retryProbe,
        10 + State.DashRetryMaximum + 0.001
    )
    local deferredWatcher = {}
    local deferredTracks = {}
    for index = 1, State.MaxDeferredDashAttacks + 1 do
        local trackProbe = { IsPlaying = true }
        deferredTracks[index] = trackProbe
        State:StoreDeferredDashAttack(deferredWatcher, {
            Track = trackProbe,
            At = 20 + index * 0.001,
            Generation = State.Generation,
            WasPlaying = true,
        })
    end
    result.DashRetryQueueBounded = deferredWatcher.DeferredDashAttacks
        and #deferredWatcher.DeferredDashAttacks
            == State.MaxDeferredDashAttacks
        and deferredWatcher.DeferredDashAttacks[1].Track
            == deferredTracks[2]
    local takenRetries = State:TakeDeferredDashAttacks(
        deferredWatcher,
        20.02
    )
    result.DashRetryQueueConsumed = #takenRetries
            == State.MaxDeferredDashAttacks
        and deferredWatcher.DeferredDashAttacks == nil
    local stoppedRetry = {
        Track = { IsPlaying = false },
        At = 30,
        Generation = State.Generation,
        WasPlaying = true,
    }
    result.StoppedDashRetryGrace = State:IsDashRetryTrackUsable(
        stoppedRetry,
        30.02
    )
    result.CancelledDashRetryRejected = not State:IsDashRetryTrackUsable(
        stoppedRetry,
        30.081
    )
    result.DashCandidateRangeExtended =
        State:DashCandidateAcquisitionRange(10, 0.2) > 40
    result.ProvisionalDashCurveStart = math.abs(
        State:ProvisionalForwardDashDistance(nil, 0.1) - 11.375
    ) < 0.001
    result.ProvisionalDashCurveEnd = math.abs(
        State:ProvisionalForwardDashDistance(nil, 0.5) - 23.375
    ) < 0.001
    local provisionalOffset = State:ProvisionalDashOffset({
        ProvisionalDash = true,
        ProvisionalDashExpiresAt = os.clock() + 1,
        ProvisionalDashDirection = Vector3.new(1, 0, 0),
        LookDirection = Vector3.new(1, 0, 0),
    }, {
        ShortVelocity = ZERO,
        Velocity = ZERO,
    }, 0.1)
    result.ProvisionalDashOffset = math.abs(provisionalOffset.X - 11.375)
            < 0.001
        and math.abs(provisionalOffset.Z) < 0.001
    result.ExactFork = State.Profiles
        and State.Profiles["85793691404836"]
        and State.Profiles["85793691404836"].Exact == true
    local forkOne = State.Profiles and State.Profiles["85793691404836"]
    local forkTwo = State.Profiles and State.Profiles["86197206792061"]
    result.LateForkWindow = forkOne and forkTwo
        and forkOne.ActiveStart <= 0.10
        and forkOne.ActiveEnd >= 0.62
        and forkTwo.ActiveStart <= 0.105
        and forkTwo.ActiveEnd >= 0.62
    local fightOne = State.Profiles
        and State.Profiles["114928327045353"]
    local fightTwo = State.Profiles
        and State.Profiles["135690448001690"]
    local fightThree = State.Profiles
        and State.Profiles["103355259844069"]
    local fightCounter = State.Profiles
        and State.Profiles["125906547773381"]
    result.FightBackExactWindows = fightOne and fightTwo
        and fightThree and fightCounter
        and fightOne.ActiveStart <= 0.075 and fightOne.ActiveEnd >= 0.64
        and fightTwo.ActiveStart <= 0.075 and fightTwo.ActiveEnd >= 0.66
        and fightThree.ActiveStart <= 0.06 and fightThree.ActiveEnd >= 0.52
        and fightCounter.ActiveStart <= 0.08
        and fightCounter.ActiveEnd >= 0.76
    result.FightBackComboTailBounded = fightOne
        and fightOne.ComboFamily == "FightBack"
        and #fightOne.ComboTail == 2
        and #fightThree.ComboTail == 1
        and #fightCounter.ComboTail == 1
    local punchThreeForward = analyticThreatRelevant(
        fightThree,
        17.5,
        toward,
        toward,
        0,
        0,
        0,
        0.2,
        0.9,
        false,
        0,
        false
    )
    local counterForward = analyticThreatRelevant(
        fightCounter,
        23.1,
        toward,
        toward,
        0,
        0,
        0,
        0.2,
        0.9,
        false,
        0,
        false
    )
    local counterSide = analyticThreatRelevant(
        fightCounter,
        23.1,
        toward,
        Vector3.new(1, 0, 0),
        0,
        0,
        0,
        0.2,
        0.9,
        false,
        0,
        false
    )
    result.FightBackObservedReach = punchThreeForward == true
        and counterForward == true and counterSide == false
    local lifeDrain = State.Profiles
        and State.Profiles["109822392402606"]
    local weakLifeDrain = State.Profiles
        and State.Profiles["82579449181823"]
    result.LifeDrainStartupProfiles = lifeDrain and weakLifeDrain
        and lifeDrain.Exact == true and weakLifeDrain.Exact == true
        and lifeDrain.TravelHitbox == true
        and weakLifeDrain.TravelHitbox == true
    result.LifeDrainPostGrabExcluded = State.Profiles
        and State.Profiles["116316368196291"] == nil
        and State.Profiles["129652163918670"] == nil
    local selectorConfirmedAt = 10 - self.FixedReactionMilliseconds / 1000 - 0.001
    local selectorPrimary = {
        FirstConfirmedAt = selectorConfirmedAt,
        Deadline = 10.01,
        TerrainBlockedUntil = 10.025,
        Profile = { Name = "Blocked primary" },
    }
    local selectorSecondary = {
        FirstConfirmedAt = selectorConfirmedAt,
        Deadline = 10.02,
        Profile = { Name = "Actionable secondary" },
    }
    local selectedSecondary, selectedIndex, selectorReason =
        self:SelectActionThreat({ selectorPrimary, selectorSecondary }, 10)
    result.BlockedPrimarySkipped = selectedSecondary == selectorSecondary
        and selectedIndex == 2
        and selectorReason == "Terrain route retry"
    local selectedPrimary, primaryIndex = self:SelectActionThreat(
        { selectorPrimary, selectorSecondary },
        10.026
    )
    result.PrimaryRestoredAfterRetry = selectedPrimary == selectorPrimary
        and primaryIndex == 1
    selectorSecondary.RequestCount = 2
    local allBlocked, allBlockedIndex = self:SelectActionThreat(
        { selectorPrimary, selectorSecondary },
        10
    )
    result.AllBlockedFallsBackSafely = allBlocked == selectorPrimary
        and allBlockedIndex == 1
    local waitingReaction = { FirstConfirmedAt = 10, Deadline = 9 }
    local readyReaction = { FirstConfirmedAt = 9.8, Deadline = 11 }
    local reactionSelected, reactionIndex, reactionBlock =
        timingProbe:SelectActionThreat({ waitingReaction, readyReaction }, 10)
    result.ReadySecondarySkipsReactionWait = reactionSelected == readyReaction
        and reactionIndex == 2 and reactionBlock == "Reaction wait"
    result.NativeCooldownPreserved = getNativeCooldown(nil) >= 1.5
    result.ExactThrow = State.Profiles
        and State.Profiles["72557176302052"]
        and State.Profiles["72557176302052"].ProjectileSignature == "fork"
    result.NewThreatProfilesBound = State.Profiles
        and State.Profiles["115925088060952"]
        and State.Profiles["124127720565083"]
        and State.Profiles["76323709902827"]
        and State.Profiles["131235569946744"]
        and State.Profiles["128733894961951"]
        and State.Profiles["81533666958052"] ~= nil
    result.PostContactProfilesExcluded = State.Profiles
        and State.Profiles["73530170623957"] == nil
        and State.Profiles["90015711020567"] == nil
        and State.Profiles["82935310906147"] == nil
        and State.Profiles["105341857343164"] == nil
        and State.Profiles["95623680038308"] == nil
        and State.Profiles["79549040943367"] == nil
    local umbrellaProfile = State.Profiles
        and State.Profiles["93373403484012"]
    result.UmbrellaPhysicalTipBound = umbrellaProfile
        and umbrellaProfile.WeaponParts[1] == "Plane.010"
        and umbrellaProfile.TipAttachments[1] == "P1"
        and umbrellaProfile.TipAttachments[2] == "P"
    result.DynamicPostContactDenyTokens = hasNameToken(
        "forkbeatdownqteblockhit",
        PASSIVE_NAME_TOKENS
    ) and not hasNameToken("forkbeatdown", ATTACK_NAME_TOKENS)
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
    result.BoundedMpc = MAX_MPC_DELAYS == 1
        and MAX_PATH_HYPOTHESES <= 5
        and MAX_MPC_TESTS <= 2200
        and MPC_WORK_BUDGET <= 0.0035
        and self.MpcTerrainBudgetFraction <= 0.4
        and self.MaxMpcTerrainHeadings == 4
        and self.MaxFastMpcTerrainHeadings == 4
        and self.MaxMpcRobustControls <= 4
        and self.MinimumMpcCoarseControls >= 8
        and self.ComboTailHorizon >= MPC_ARM_WINDOW + 1.55
    local acknowledgementProbe = {
        Acknowledged = true,
        VerificationExpiresAt = 10.05,
    }
    result.PhantomAckNeedsPhysicsGrace =
        not self:DashAcknowledgementReady(
            acknowledgementProbe,
            10,
            false
        )
        and self:DashAcknowledgementReady(
            acknowledgementProbe,
            10.05,
            false
        )
        and self:DashAcknowledgementReady({}, 10, true)
    local lateAcknowledgementProbe = {
        ExpiresAt = 10,
        VerificationExpiresAt = 10.08,
    }
    self:PreserveDashVerificationGrace(lateAcknowledgementProbe, 10)
    result.LateAckPreservesVerification =
        lateAcknowledgementProbe.ExpiresAt > 10.08
    result.PhantomMotionVerification = self:DashMotionVerified(
        2,
        180,
        0.95,
        0.95,
        0.02
    )
    result.WalkingMotionNotDash = not self:DashMotionVerified(
        1.44,
        16,
        1,
        1,
        0.09
    )
    result.PerpendicularMotionNotDash = not self:DashMotionVerified(
        2,
        180,
        0.1,
        0.1,
        0.02
    )
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
    local deepBarrier = Instance.new("Folder")
    deepBarrier.Name = "barriers"
    local deepParent = deepBarrier
    for index = 1, 24 do
        local model = Instance.new("Model")
        model.Name = "Nested_" .. tostring(index)
        model.Parent = deepParent
        deepParent = model
    end
    local deepBarrierPart = Instance.new("Part")
    deepBarrierPart.Parent = deepParent
    local valueHazard = Instance.new("Folder")
    valueHazard.Name = "OrdinaryContainer"
    local touchDamage = Instance.new("NumberValue")
    touchDamage.Name = "TouchDamage"
    touchDamage.Value = 25
    touchDamage.Parent = valueHazard
    local valueHazardPart = Instance.new("Part")
    valueHazardPart.Parent = valueHazard
    result.GeometryRoleClassification = self:IsBarrierGeometry(barrierPart)
        and not self:IsBarrierGeometry(ordinaryPart)
        and self:IsHazardGeometry(hazardPart)
        and not self:IsHazardGeometry(ordinaryPart)
        and self:IsBarrierGeometry(deepBarrierPart)
        and self:IsHazardGeometry(valueHazardPart)
    local sweepContainer = Instance.new("Folder")
    local sweepPart = Instance.new("Part")
    sweepPart.Size = Vector3.new(2, 6, 4)
    sweepPart.CFrame = CFrame.new(5, 0, 0)
    sweepPart.Parent = sweepContainer
    result.MapOrientedBoxSweep = self:SegmentIntersectsExpandedPart(
        Vector3.new(0, 0, 0),
        Vector3.new(10, 0, 0),
        sweepPart
    ) and not self:SegmentIntersectsExpandedPart(
        Vector3.new(0, 20, 0),
        Vector3.new(10, 20, 0),
        sweepPart
    )
    local projectileAliases = {
        CardModel = "card",
        Coal = "coal",
        IceShuriken = "shuriken",
        RabbitHexBolt = "rabbithex",
        InkPole = "pole",
    }
    local aliasesPass = true
    for name, expected in pairs(projectileAliases) do
        local signatureProbe = Instance.new("Part")
        signatureProbe.Name = name
        local actual = projectileSignatureFor(signatureProbe)
        aliasesPass = aliasesPass and actual == expected
        signatureProbe:Destroy()
    end
    result.ExpandedProjectileCoverage = aliasesPass
    sweepContainer:Destroy()
    barrierProbe:Destroy()
    ordinaryModel:Destroy()
    hazardProbe:Destroy()
    deepBarrier:Destroy()
    valueHazard:Destroy()
    result.BoundedGroundSweep = self.GroundProbeSpacing <= 1.5
        and self.MaximumGroundSamples <= 20
        and self.MaximumExtendedGroundSamples >= self.MaximumGroundSamples
        and self.MaximumExtendedGroundSamples <= 96
        and self.GroundFootprintRadius >= 1.5
        and self.MaximumAdaptiveGroundSpacing >= self.GroundProbeSpacing
        and self.MaximumAdaptiveGroundSpacing <= 2
        and self.PhantomGroundMinimumNormalY >= 0.7
        and self.MapScanPerFrame >= 32
        and self.MapScanPerFrame <= 512
        and self.MapMotionSamplesPerFrame <= 128
        and self.MapHazardSweepLimit <= 512
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
    local fallbackProbe = Instance.new("Model")
    fallbackProbe:SetAttribute("RecentDash", 5)
    self:ResetPhantomFallback(fallbackProbe)
    local rollbackCountBefore = self.PhantomFallbackRollbacks
    local fallbackSpend = self:RecordPhantomFallbackSpend(
        fallbackProbe,
        "Fallback",
        100,
        5
    )
    local suppressionArmed =
        self.PhantomFallbackSuppressRecentDashUntil > 100
    local fallbackRolledBack = self:RollbackPhantomFallbackSpend(
        fallbackProbe,
        fallbackSpend,
        5
    )
    result.FallbackSpendRollback = fallbackSpend > 0
        and suppressionArmed
        and fallbackRolledBack
        and self.PhantomFallbackStacks == 0
        and self.PhantomFallbackRollbacks == rollbackCountBefore + 1
    fallbackProbe:SetAttribute("RecentDash", 6)
    self:ResetPhantomFallback(fallbackProbe)
    self:RecordPhantomFallbackSpend(
        fallbackProbe,
        "Fallback",
        101,
        5
    )
    result.SynchronousRecentDashNotSuppressed =
        self.PhantomFallbackSuppressRecentDashUntil == 0
    fallbackProbe:Destroy()
    self:ResetPhantomFallback(nil)
    self.PhantomFallbackPowerActive = false
    self:ClearDashControllerCache()
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
    result.TerrainIncompleteClassification =
        self:IsTerrainCheckIncomplete("Terrain route deadline")
        and self:IsTerrainCheckIncomplete("Ground sweep deadline")
        and self:IsTerrainCheckIncomplete("Ground coverage budget")
        and self:IsTerrainCheckIncomplete("Map audit pending")
        and not self:IsTerrainCheckIncomplete("Unsafe drop")
        and not self:IsTerrainCheckIncomplete("Barrier crosses dash path")
    local expiredSafe, expiredReason = self:EvaluateTerrainRoute(
        nil, { Position = ZERO }, nil, ZERO, 0, nil, true, os.clock() - 1
    )
    result.ExpiredTerrainFailsClosed = expiredSafe == false
        and expiredReason == "Terrain route deadline"
    local mapModel = Instance.new("Model")
    mapModel.Name = "Map"
    local mapFolder = Instance.new("Folder")
    mapFolder.Name = "Map"
    result.ModelAndFolderMapRoots = self:IsMapRoot(mapModel)
        and self:IsMapRoot(mapFolder)
    mapModel:Destroy()
    mapFolder:Destroy()
    local sweepProbe = setmetatable({
        MapAuditComplete = true, MapHazardList = {}, MapBarrierList = {},
        MapRegistry = {}, MapHazardSweepLimit = 512,
        IsMapMember = function() return true end,
        GeometryRoleFor = function() return { Barrier = true } end,
        SegmentIntersectsExpandedPart = function() return true end,
    }, { __index = self })
    for index = 1, 600 do
        local part = { Parent = true, Size = Vector3.new(1, 1, 1),
            Position = Vector3.new(100000 + index, 0, 0) }
        sweepProbe.MapBarrierList[index] = part
        sweepProbe.MapRegistry[part] = true
    end
    local farHit, _, farComplete = sweepProbe:SweptMapRoleCollision(
        ZERO, Vector3.new(5, 0, 0), nil
    )
    local nearPart = { Parent = true, Size = Vector3.new(1, 1, 1), Position = ZERO }
    sweepProbe.MapBarrierList[601] = nearPart
    sweepProbe.MapRegistry[nearPart] = true
    local nearHit, _, nearComplete = sweepProbe:SweptMapRoleCollision(
        ZERO, Vector3.new(5, 0, 0), nil
    )
    result.DistantBarriersDoNotExhaustSweep = farHit == nil and farComplete == true
        and nearHit == nearPart and nearComplete == true
    local heldProbe = { WeaponSample = {
        Part = { Parent = true }, Base = Vector3.new(0, 0, -2),
        Tip = Vector3.new(0, 0, -5), Radius = 0.3,
        BaseVelocity = Vector3.new(900, 0, 0),
        TipVelocity = Vector3.new(-900, 0, 0),
        CFrame = CFrame.new(0, 0, -3.5), Size = Vector3.new(0.4, 0.4, 3),
        CenterVelocity = Vector3.new(900, 0, 0), AngularVelocity = ZERO,
    } }
    local heldMotion = { Position = ZERO, Velocity = ZERO, Acceleration = ZERO }
    local heldBase, heldTip = weaponSegmentAt(heldProbe, 0.1, heldMotion)
    result.HeldWeaponCannotStretch = math.abs((heldTip - heldBase).Magnitude - 3) < 0.001
        and heldBase.Magnitude < 7 and heldTip.Magnitude < 7
    local obbBase, obbTip = weaponObbSegmentAt(heldProbe, 0.1, heldMotion)
    result.HeldObbCannotFlyAway = obbBase.Magnitude < 7 and obbTip.Magnitude < 7
    heldMotion.Velocity = Vector3.new(180, 0, 0)
    heldProbe.WeaponSample.BaseVelocity = heldMotion.Velocity
    heldProbe.WeaponSample.TipVelocity = heldMotion.Velocity
    local dashBase, dashTip = weaponSegmentAt(heldProbe, 0.1, heldMotion)
    result.HeldWeaponPreservesDashTravel = math.abs(dashBase.X - 18) < 0.001
        and math.abs(dashTip.X - 18) < 0.001
    local ownCharacter = LocalPlayer.Character
    if ownCharacter then
        local ownThreat = { Character = ownCharacter, ContactIn = 0,
            Emergency = true, Deadline = 0 }
        local valid, reason = evaluateThreat(ownThreat, os.clock(), ownCharacter, nil, nil)
        result.OwnAnimationRejected = valid == false and reason == "self attack"
            and ownThreat.ContactIn == nil and ownThreat.Deadline == math.huge
        local savedBlock = State.LastBlockReason
        result.OwnAttackCannotDodge = nativeDodge(ownThreat) == false
            and State.LastBlockReason == "Own attack ignored"
        State.LastBlockReason = savedBlock
    end
    local cancelledProbe = { Track = { IsPlaying = false }, StoppedPhase = 0.01,
        DashAttack = true, DashWalkBridgeUntil = math.huge }
    result.DashCannotReviveCancelledWindup = self:IsCancelledAttack(cancelledProbe, 0.3)
    cancelledProbe.StoppedPhase = 0.35
    result.ActiveAttackSurvivesTrackStop = not self:IsCancelledAttack(cancelledProbe, 0.3)
    cancelledProbe.Track.IsPlaying = true
    cancelledProbe.StoppedPhase = 0.01
    result.PlayingWindupNotCancelled = not self:IsCancelledAttack(cancelledProbe, 0.3)
    result.HBVelocityCap = (self:HBVelocityOffset(Vector3.new(250, 80, 0), true, false)
        - Vector3.new(10, 0, 0)).Magnitude < 0.001
    result.HBPredictionOptIn = self:HBVelocityOffset(Vector3.new(250, 0, 0), false, false) == ZERO
        and self:HBVelocityOffset(Vector3.new(250, 0, 0), true, true) == ZERO
    result.HBBoxOverlap = self:HBBodyClearance(CFrame.new(), Vector3.new(2, 2, 2), ZERO, 0) < 0
        and self:HBBodyClearance(CFrame.new(), Vector3.new(2, 2, 2), Vector3.new(20, 0, 0), 0) > 0
    local rotated = CFrame.Angles(0, math.pi / 2, 0)
    result.HBBoxRotation = self:HBBodyClearance(rotated, Vector3.new(20, 2, 2), Vector3.new(0, 0, 8), 0) < 0
        and self:HBBodyClearance(rotated, Vector3.new(20, 2, 2), Vector3.new(8, 0, 0), 0) > 0
    local testId = "999999999991"
    local savedHB = self.ConfirmedHBProfiles[testId]
    local spec = { Confirmed = true, Source = "Synthetic self-test only",
        HitboxSize = Vector3.new(2, 3, 4), CFrameOffset = CFrame.new(0, 0, -3),
        ActiveStart = 0.2, ActiveEnd = 0.4 }
    result.HBRequiresEvidence = not self:RegisterHBProfile(testId, {})
        and self:RegisterHBProfile(testId, spec)
    local hbThreat = { TimingKey = testId, Profile = { Kind = "Melee" } }
    result.HBConfirmedRouting = self:GetHBProfile(hbThreat) ~= nil
    hbThreat.PhysicalProjectile = {}
    result.HBLeavesProjectileModel = self:GetHBProfile(hbThreat) == nil
    self.ConfirmedHBProfiles[testId] = savedHB
    local holder = Instance.new("Folder")
    local target = Instance.new("Model")
    target.Parent = holder
    local immunity = Instance.new("Folder")
    immunity.Name = "IFrame"
    immunity.Parent = target
    result.HBInvulnerabilityExclusion = not self:HBTargetAllowed(nil, target, {})
    immunity:Destroy()
    result.HBSelfExclusion = not self:HBTargetAllowed(target, target, {})
    holder:Destroy()
    local passed = true
    -- End-to-end stationary geometry: no velocity/closing-speed requirement.
    do
        local stopped = {
            Position = ZERO, Velocity = Vector3.new(40, 0, 0),
            ShortVelocity = Vector3.new(40, 0, 0), Acceleration = Vector3.new(-100, 0, 0),
            Jerk = ZERO, SampleAt = 10.02, LastChangedAt = 10,
        }
        local uncorrected = table.clone(stopped)
        local corrections = self.LocalRestCorrections
        local first = self:ObserveLocalRest(stopped, ZERO, ZERO, 0.01, 10.01, true)
        local second = self:ObserveLocalRest(stopped, ZERO, ZERO, 0.01, 10.02, true)
        result.RestNeedsCorroboration = not first and second
        result.RestClearsDriftAndAcceleration = predictPosition(stopped, 0.3, true).Magnitude < 0.001
            and predictionVelocity(stopped, true).Magnitude < 0.001
        local stillProfile = table.clone(PROFILE_FAST_MELEE)
        local attacker = { Position = Vector3.new(0,0,-5), Velocity = ZERO,
            ShortVelocity = ZERO, Acceleration = ZERO, SampleAt=10,LastChangedAt=10 }
        local attack = { Profile = stillProfile, LookDirection = Vector3.new(0,0,1) }
        result.StationaryMeleeContact = attackHitsAt(attack, 0.15, stopped, attacker, 0.5, nil, true)
        result.StaleLocalMotionFalseNegativeFixed = not attackHitsAt(attack, 0.3, uncorrected, attacker, 0.5, nil, true)
            and attackHitsAt(attack, 0.3, stopped, attacker, 0.5, nil, true)
        local ready = { FirstConfirmedAt = 10, ContactIn = 0.15 }
        result.StationaryReactionReady = self:ReactionReady(ready, 11)
        stopped.Velocity = Vector3.new(20, 7, 0)
        stopped.ShortVelocity = stopped.Velocity
        stopped.Acceleration = Vector3.new(-100, 9, 0)
        self:ObserveLocalRest(stopped, ZERO, ZERO, 0.01, 10.03, true)
        result.RestPreservesVertical = stopped.Velocity.Y == 7 and stopped.Acceleration.Y == 9
        local remote = {Velocity=Vector3.new(100,0,0),ShortVelocity=Vector3.new(100,0,0),Acceleration=ZERO,Jerk=ZERO}
        self:ObserveLocalRest(remote,ZERO,ZERO,.1,20,false)
        result.RemotePauseNotLocalRest = remote.Velocity.X == 100
        self:ObserveLocalRest(stopped,Vector3.new(.1,0,0),Vector3.new(10,0,0),.01,10.04,true)
        result.RestUnlocksOnMovement = not stopped.ObservedRest and stopped.RestSamples == 0
        self.LocalRestCorrections = corrections
        local probe = setmetatable({ FrameBudgetActive=true, FrameDeadline=9,
            MinimumActionPlanningBudget=.0018, PlanningReserveUses=0 }, {__index=self})
        local deadline = probe:ActionPlanningDeadline(10,.0018)
        result.ExhaustedFrameKeepsActionReserve = deadline >= 10.001799 and probe.PlanningReserveUses == 1
        probe.FrameDeadline=10.0001
        result.NearExhaustedFrameKeepsActionReserve = probe:ActionPlanningDeadline(10,.002) >= 10.001799
        probe.FrameDeadline=12
        result.ActionReserveBounded = probe:ActionPlanningDeadline(10,.0032) <= 10.003201
        probe.FrameBudgetActive=false
        result.CallbackPlannerBounded = probe:ActionPlanningDeadline(10,.002) <= 10.002001
    end
    do
        local order = {}
        local direction = Vector3.new(1, 0, 0)
        local moved, payload
        local humanoid = { Move = function(_, value, relative)
            moved = value
            order[#order + 1] = relative == false and "direction" or "invalid"
        end }
        local info = { Fire = function(_, value)
            payload = value
            order[#order + 1] = "event"
        end }
        local releasedAt = self:ReleaseNativeDash(info, humanoid, direction)
        result.NativeEventDirectionBeforeRelease = moved == direction
            and #order == 2 and order[1] == "direction" and order[2] == "event"
        result.NativeEventSingleUnchargedPayload = payload.DashingReleased == true
            and payload.Dashing == nil and finiteNumber(releasedAt)
        result.NativeEventDispatchConfigured = self.DashDispatchMode == "Native event"
            and self.StartMovementKeyPulse == nil and self.StopMovementKeyPulse == nil
    end
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
        State.FrameBudgetActive = false
        State.FrameDeadline = 0
        if not ok then
            reportError("prediction engine", message)
        end
    end)
end

local function stopActiveWork()
    State:StopDodgeAudits("Disabled or reset")
    State.Initializing = false
    restoreDirectionLease(nil, false)
    local pendingAttempt = State.AttemptPending
    if pendingAttempt then
        State:RollbackPhantomFallbackSpend(
            pendingAttempt.Character,
            pendingAttempt.FallbackSpendRecorded,
            pendingAttempt.BeforeRecentDash
        )
    end
    disconnect(State.Engine)
    State.Engine = nil
    disconnect(State.ProjectileEffectsConnection)
    State.ProjectileEffectsConnection = nil
    clearConnections(State.ActiveConnections)
    State:ClearMapIndex()
    for _, watcher in pairs(State.Watchers) do
        disconnect(watcher.AnimationConnection)
        disconnect(watcher.DescendantAddedConnection)
        disconnect(watcher.DescendantRemovingConnection)
    end
    table.clear(State.Watchers)
    table.clear(State.Pending)
    table.clear(State.PendingIndex)
    table.clear(State.RecentEnemyDashes)
    table.clear(State.RecentEnemyDashDirections)
    table.clear(State.RecentEnemyDashWalkBridgeUntil)
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
    State.FrameBudgetActive = false
    State.PhantomFallbackPowerActive = false
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
        self.ProfileRefreshAttempts = 0
        self.ProfileRefreshes = 0
        local generation = self.Generation
        local ok, message = xpcall(function()
            self:InitializeNativeReaders()
            buildProfiles(true)
            self:BeginMapAudit(generation)
            self:ProcessMapAudit(os.clock())
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
                            State:StopDodgeAudits("Respawn")
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

State:BindMobileToggle()
updateStatus(true)
