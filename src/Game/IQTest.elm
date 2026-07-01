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


type alias DingSchedule =
    { delay : Float, nextRandom : Bool }


type alias IQTestInit =
    { delay : Float, nextRandom : Bool, fakeFlashPoint : Int }


type alias IQTestScreenState =
    { questionIdx : Int
    , totalDings : Int
    , fakeFlashUsed : Bool
    , in50PercentPhase : Bool
    }


-- State for the countdown shown between pressing "Begin" and the test starting.
type alias IQTestCountdownState =
    { questionIdx : Int
    , totalDings : Int
    , fakeFlashUsed : Bool
    , in50PercentPhase : Bool
    , countdown : Int
    , initData : IQTestInit
    }


type alias IQTestState =
    { questionIdx : Int
    , dingCount : Int
    , totalDings : Int
    , isFlashing : Bool
    , dingActive : Bool
    , fakeFlashActive : Bool
    , loudPlaying : Bool
    , fakeFlashUsed : Bool
    , fakeFlashPoint : Int
    , nextRandom : Bool
    , in50PercentPhase : Bool
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


dingScheduleGen : Random.Generator DingSchedule
dingScheduleGen =
    Random.map2 (\d r -> { delay = d, nextRandom = r })
        (Random.float minDingDelay maxDingDelay)
        (Random.map (\n -> n < 0.5) (Random.float 0 1))


iqTestInitGen : Int -> Random.Generator IQTestInit
iqTestInitGen total =
    let
        lo =
            Basics.max 0 (floor (fakeFlashRangeLo * toFloat total))

        hi =
            Basics.max lo (Basics.min (total - 1) (floor (fakeFlashRangeHi * toFloat total)))
    in
    Random.map3 (\d r fp -> { delay = d, nextRandom = r, fakeFlashPoint = fp })
        (Random.float minDingDelay maxDingDelay)
        (Random.map (\n -> n < 0.5) (Random.float 0 1))
        (Random.int lo hi)


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
