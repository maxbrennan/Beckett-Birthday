module Game.IQTest exposing (..)

import Random


-- Set to True to enable debug mode (smaller counts, faster delays, no AirPods required).
debug : Bool
debug =
    False


-- ── Configuration ─────────────────────────────────────────────────────────────


-- Total correct ding presses required to pass the IQ test.
-- Debug: 10  |  Production: 100
iqQuestionCount : Int
iqQuestionCount =
    if debug then
        10

    else
        100


-- Hard cap on totalDings after fake-flash catches double it. Bounds both the
-- server's authoritative count and the client's display copy so they agree, and
-- stops a client spamming catches from blowing the count up unboundedly.
maxTotalDings : Int
maxTotalDings =
    iqQuestionCount * 8


-- Minimum real dings cleared this run before a fail (or fake-flash catch) becomes
-- eligible for the one-time skip offer -- see Server.elm's decideIqOffer.
iqOfferMinDings : Int
iqOfferMinDings =
    5


-- Lower bound (as a fraction of iqQuestionCount) for the fake-flash trap position.
-- Debug: 0.65  |  Production: 0.85
fakeFlashRangeLo : Float
fakeFlashRangeLo =
    if debug then
        0.65

    else
        0.85


-- Upper bound (as a fraction of iqQuestionCount) for the fake-flash trap position.
-- Debug: 0.75  |  Production: 0.95
fakeFlashRangeHi : Float
fakeFlashRangeHi =
    if debug then
        0.75

    else
        0.95


-- Minimum milliseconds between successive dings.
-- Debug: 100  |  Production: 2000
minDingDelay : Float
minDingDelay =
    if debug then
        2000

    else
        2000


-- Maximum milliseconds between successive dings.
-- Debug: 500  |  Production: 15000
maxDingDelay : Float
maxDingDelay =
    if debug then
        5000

    else
        15000


-- Duration (ms) of the green flash visual.
iqFlashDuration : Float
iqFlashDuration =
    250


-- Duration (ms) of the window in which a space-bar press counts as a ding response.
iqWindowDuration : Float
iqWindowDuration =
    2000


-- Volume (0–1) for the ding sound effect.
iqDingVolume : Float
iqDingVolume =
    0.8


-- Ding count at/above which the loud "gag" video should start playing.
iqLoudDingThreshold : Int
iqLoudDingThreshold =
    4


-- Delay (ms) before the loud video actually starts once the loud threshold is
-- reached, so the gag doesn't feel instantaneous.
iqLoudDelay : Float
iqLoudDelay =
    3000


-- Number of preloaded ding-audio slots cycled round-robin so rapid
-- back-to-back triggers (e.g. the fake-flash countdown at 80 ms cadence)
-- can play without cutting each other off.
dingSlotCount : Int
dingSlotCount =
    8


-- Milliseconds per tick for the counter animation on the fake-flash penalty screen.
counterTickMs : Float
counterTickMs =
    80


-- ── Types ─────────────────────────────────────────────────────────────────────


-- The IQ test is now driven by the server (all timing, the ding/question count,
-- and the real/fake decision). These client screen states hold only what the UI
-- renders plus what the client needs to react to a raw key press; `totalDings`
-- here is a display copy synced from the server, not the source of truth.
type alias IQTestScreenState =
    { questionIdx : Int
    , totalDings : Int

    -- A server-granted, not-yet-shown one-time skip offer (see Server.elm's
    -- decideIqOffer/Model.iqOfferGrants), carrying the totalDings to display
    -- once the offer screen is actually entered. Set by Main.elm's
    -- ServerIqOfferDecision handler (or re-derived fresh on reconnect by
    -- Server.elm's deriveIqScreen), and consumed locally by IQTestBeginPressed,
    -- which routes to IQTestSkipOfferScreen instead of starting the countdown.
    -- Always Nothing on IQTestSkipOfferScreen itself (this type is shared, but
    -- the field is meaningless once already on the offer screen).
    , pendingSkipOffer : Maybe Int

    -- The server's isLastChance verdict (see Server.elm's decideIqOffer), carried
    -- alongside pendingSkipOffer/skipOffer even while still on IQTestScreen/
    -- FakeFlashCaughtScreen (where nothing reads it yet) purely so it survives the
    -- hand-off into IQTestSkipOfferScreen, the only place View.elm actually branches
    -- on it. Meaningless (always False) whenever there's no pending offer at all.
    , offerIsLastChance : Bool
    }


-- State for the countdown shown between pressing "Begin" and the test starting.
type alias IQTestCountdownState =
    { questionIdx : Int
    , totalDings : Int
    , countdown : Int
    }


type alias IQTestState =
    { questionIdx : Int
    , dingCount : Int
    , totalDings : Int
    , isFlashing : Bool
    , dingActive : Bool
    , fakeFlashActive : Bool
    , fakeIsTrap : Bool -- when fakeFlashActive: pressing catches (cutscene) vs fails
    , loudPlaying : Bool
    }


type FakeFlashPhase
    = FfDelay
    | FfText1In
    | FfText1Hold
    | FfText1Out
    | FfText2In
    | FfText2Hold
    | FfText2Out
    | FfCounterIn
    | FfTickNumerator
    | FfTickDelay
    | FfTickDenominator
    | FfCounterOut


type alias FakeFlashCaughtState =
    { questionIdx : Int
    , originalTotal : Int
    , displayNumerator : Int
    , displayDenominator : Int
    , phase : FakeFlashPhase

    -- The server's answer to "was the skip offer granted for this catch" (see
    -- Server.elm's decideIqOffer) -- Nothing until ServerIqOfferDecision arrives (it's
    -- sent in reply to the ClientIqCaught this cutscene started from, so it typically
    -- lands well before FfCounterOut, the only phase that reads it). Just totalDings
    -- once granted; stays Nothing forever if denied.
    , skipOffer : Maybe Int

    -- Mirrors IQTestScreenState.offerIsLastChance -- see its doc comment.
    , offerIsLastChance : Bool
    }


-- Which of the two triggers (see Server.elm's decideIqOffer) a cached grant came
-- from -- see CachedOfferGrant below.
type OfferGrantTrigger
    = FailTrigger
    | CatchTrigger


{-| The client's own local-disk mirror of a live, outstanding skip-offer grant
(see Server.elm's Model.iqOfferGrants/RegistryEntry.iqOfferGrant) -- written to
disk whenever the client's own Model reflects one, read back at app launch so
the very first rendered screen can already show the offer-eligible variant
instead of a generic loading screen while the WebSocket round trip is still in
flight. Purely an optimistic accelerator: the eventual ServerStateUpdate is
always authoritative and overwrites whatever this seeded, so a stale/wrong
cache is a cosmetic risk at worst (see Main.elm's WsClientReady/
ServerStateUpdate handling).
-}
type alias CachedOfferGrant =
    { questionIdx : Int
    , totalDings : Int
    , trigger : OfferGrantTrigger
    , offerIsLastChance : Bool
    }


-- Phases of the count-up animation shown when the player accepts the skip
-- offer: the counter holds at 0/total, ticks up by one (with a ding) every
-- counterTickMs until it reaches total/total, then holds before advancing to
-- the next song. See Main.elm's
-- IQSkipOfferAccepted/IQSkipAnimNextPhase/IQSkipCounterTick.
type IQSkipPhase
    = SkipCounterIn
    | SkipTick
    | SkipCounterOut


type alias IQSkipAnimState =
    { questionIdx : Int
    , displayCount : Int
    , total : Int
    , phase : IQSkipPhase
    }


-- ── Generators ────────────────────────────────────────────────────────────────


-- The trap position (which real-ding index secretly becomes a fake flash),
-- picked in [fakeFlashRangeLo, fakeFlashRangeHi] × total. Shared by the server,
-- which now owns the trap decision, so both sides agree on the range.
fakeFlashPointGen : Int -> Random.Generator Int
fakeFlashPointGen total =
    let
        lo =
            Basics.max 0 (floor (fakeFlashRangeLo * toFloat total))

        hi =
            Basics.max lo (Basics.min (total - 1) (floor (fakeFlashRangeHi * toFloat total)))
    in
    Random.int lo hi


-- Delay (ms) before the next ding. The server draws this to enforce the wait,
-- so the client can no longer fast-forward the gap between dings.
dingDelayGen : Random.Generator Float
dingDelayGen =
    Random.float minDingDelay maxDingDelay


-- A fair coin; drives the 50%-phase fake/real choice.
coinFlipGen : Random.Generator Bool
coinFlipGen =
    Random.map (\n -> n < 0.5) (Random.float 0 1)


-- ── Pure Helpers ──────────────────────────────────────────────────────────────


isCounterBig : FakeFlashPhase -> Bool
isCounterBig phase =
    case phase of
        FfCounterIn ->
            True

        FfTickNumerator ->
            True

        FfTickDelay ->
            True

        FfTickDenominator ->
            True

        FfCounterOut ->
            True

        _ ->
            False


-- Returns the dingKey value of the last trigger for a given audio slot index.
-- Used to determine whether a slot's audio is still "fresh" relative to the current dingKey.
lastTriggerForSlot : Int -> Int -> Int
lastTriggerForSlot slotIndex dingKey =
    if dingKey <= slotIndex then
        0

    else
        dingKey - modBy dingSlotCount (dingKey - 1 - slotIndex)


-- The client's optimistic guess at how a cleared ding advances the count, sent
-- alongside the report so the UI updates immediately rather than waiting on the
-- server's authoritative ServerIqDing/ServerIqTestComplete. Mirrors the server's
-- own `advanceOnClear` rule (see Server.elm) so the guess is actually right, not
-- just eventually corrected.
type SpaceBarOutcome
    = CaughtTrap FakeFlashCaughtState
    | SpaceBarFailed
    | OptimisticClear IQTestState


decideSpaceBar : IQTestState -> SpaceBarOutcome
decideSpaceBar state =
    if state.fakeFlashActive then
        if state.fakeIsTrap then
            CaughtTrap
                { questionIdx = state.questionIdx
                , originalTotal = state.totalDings
                , displayNumerator = state.dingCount
                , displayDenominator = state.totalDings
                , phase = FfDelay
                , skipOffer = Nothing
                , offerIsLastChance = False
                }

        else
            SpaceBarFailed

    else if state.dingActive then
        if state.totalDings > iqQuestionCount then
            OptimisticClear { state | dingActive = False, totalDings = state.totalDings - 1 }

        else
            OptimisticClear { state | dingActive = False, dingCount = state.dingCount + 1 }

    else
        SpaceBarFailed


-- Table for the fake-flash-caught cutscene's simple linear phase progression
-- (each phase just waits `delay` ms then advances to the next). The two phases
-- that instead kick off the ticking counter (FfCounterIn, FfTickDelay) and the
-- terminal FfCounterOut don't fit this shape and are handled separately by the
-- caller.
nextFfPhase : FakeFlashPhase -> Maybe ( FakeFlashPhase, Float )
nextFfPhase phase =
    case phase of
        FfDelay ->
            Just ( FfText1In, 1000 )

        FfText1In ->
            Just ( FfText1Hold, 2500 )

        FfText1Hold ->
            Just ( FfText1Out, 1000 )

        FfText1Out ->
            Just ( FfText2In, 800 )

        FfText2In ->
            Just ( FfText2Hold, 2500 )

        FfText2Hold ->
            Just ( FfText2Out, 1000 )

        FfText2Out ->
            Just ( FfCounterIn, 700 )

        _ ->
            Nothing


-- The fake-flash-caught cutscene's exit: back to the IQ Begin screen with the
-- doubled display count, capped to agree with the server's own doubling.
exitFakeFlash : FakeFlashCaughtState -> IQTestScreenState
exitFakeFlash state =
    { questionIdx = state.questionIdx
    , totalDings = Basics.min (state.originalTotal * 2) maxTotalDings
    , pendingSkipOffer = Nothing
    , offerIsLastChance = False
    }
