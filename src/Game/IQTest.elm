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


-- Total time allowed to complete the quiz.
-- Debug: 10 minutes  |  Production: 7 days
timeLimitMs : Float
timeLimitMs =
    if debug then
        600000

    else
        7 * 24 * 60 * 60 * 1000


-- ── Types ─────────────────────────────────────────────────────────────────────


-- The IQ test is now driven by the server (all timing, the ding/question count,
-- and the real/fake decision). These client screen states hold only what the UI
-- renders plus what the client needs to react to a raw key press; `totalDings`
-- here is a display copy synced from the server, not the source of truth.
type alias IQTestScreenState =
    { questionIdx : Int
    , totalDings : Int
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
