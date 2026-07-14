module IQTestTest exposing (..)

import Expect
import Game.IQTest
    exposing
        ( FakeFlashPhase(..)
        , IQTestState
        , SpaceBarOutcome(..)
        , coinFlipGen
        , decideSpaceBar
        , dingDelayGen
        , exitFakeFlash
        , fakeFlashPointGen
        , iqDingVolume
        , iqQuestionCount
        , isCounterBig
        , lastTriggerForSlot
        , maxDingDelay
        , maxTotalDings
        , minDingDelay
        , nextFfPhase
        )
import Random
import Test exposing (Test, describe, test)


iqState : IQTestState
iqState =
    { questionIdx = 0
    , dingCount = 0
    , totalDings = iqQuestionCount
    , isFlashing = False
    , dingActive = False
    , fakeFlashActive = False
    , fakeIsTrap = False
    , loudPlaying = False
    }


decideSpaceBarTests : Test
decideSpaceBarTests =
    describe "decideSpaceBar"
        [ test "catching the one-time trap starts the cutscene" <|
            \_ ->
                decideSpaceBar { iqState | fakeFlashActive = True, fakeIsTrap = True, dingCount = 5, totalDings = 100 }
                    |> Expect.equal
                        (CaughtTrap
                            { questionIdx = 0
                            , originalTotal = 100
                            , displayNumerator = 5
                            , displayDenominator = 100
                            , phase = FfDelay
                            , skipOffer = Nothing
                            }
                        )
        , test "pressing during a 50%-phase fake (not the trap) fails" <|
            \_ -> decideSpaceBar { iqState | fakeFlashActive = True, fakeIsTrap = False } |> Expect.equal SpaceBarFailed
        , test "pressing with nothing active fails" <|
            \_ -> decideSpaceBar iqState |> Expect.equal SpaceBarFailed
        , test "clearing a real ding while still in the doubled-punishment range grinds totalDings down" <|
            \_ ->
                decideSpaceBar { iqState | dingActive = True, dingCount = 3, totalDings = iqQuestionCount + 1 }
                    |> Expect.equal
                        (OptimisticClear { iqState | dingActive = False, dingCount = 3, totalDings = iqQuestionCount })
        , test "clearing a real ding back at the target count advances dingCount instead" <|
            \_ ->
                decideSpaceBar { iqState | dingActive = True, dingCount = 3, totalDings = iqQuestionCount }
                    |> Expect.equal
                        (OptimisticClear { iqState | dingActive = False, dingCount = 4, totalDings = iqQuestionCount })
        ]


nextFfPhaseTests : Test
nextFfPhaseTests =
    describe "nextFfPhase"
        [ test "walks the linear text/delay phases in order" <|
            \_ ->
                Expect.equal
                    [ Just ( FfText1In, 1000 )
                    , Just ( FfText1Hold, 2500 )
                    , Just ( FfText1Out, 1000 )
                    , Just ( FfText2In, 800 )
                    , Just ( FfText2Hold, 2500 )
                    , Just ( FfText2Out, 1000 )
                    , Just ( FfCounterIn, 700 )
                    ]
                    (List.map nextFfPhase [ FfDelay, FfText1In, FfText1Hold, FfText1Out, FfText2In, FfText2Hold, FfText2Out ])
        , test "Nothing for the counter/tick/terminal phases handled outside the table" <|
            \_ ->
                Expect.equal
                    [ Nothing, Nothing, Nothing, Nothing, Nothing ]
                    (List.map nextFfPhase [ FfCounterIn, FfTickNumerator, FfTickDelay, FfTickDenominator, FfCounterOut ])
        ]


exitFakeFlashTests : Test
exitFakeFlashTests =
    describe "exitFakeFlash"
        [ test "doubles the display total on exit" <|
            \_ ->
                exitFakeFlash { questionIdx = 2, originalTotal = 10, displayNumerator = 0, displayDenominator = 20, phase = FfCounterOut, skipOffer = Nothing }
                    |> Expect.equal { questionIdx = 2, totalDings = 20, pendingSkipOffer = Nothing }
        , test "caps the doubled total at maxTotalDings" <|
            \_ ->
                exitFakeFlash { questionIdx = 0, originalTotal = maxTotalDings, displayNumerator = 0, displayDenominator = 0, phase = FfCounterOut, skipOffer = Nothing }
                    |> Expect.equal { questionIdx = 0, totalDings = maxTotalDings, pendingSkipOffer = Nothing }
        ]


isCounterBigTests : Test
isCounterBigTests =
    describe "isCounterBig"
        [ test "True during the counter-visible phases" <|
            \_ ->
                Expect.equal
                    [ True, True, True, True, True ]
                    (List.map isCounterBig [ FfCounterIn, FfTickNumerator, FfTickDelay, FfTickDenominator, FfCounterOut ])
        , test "False during the text/delay phases" <|
            \_ ->
                Expect.equal
                    [ False, False, False, False, False, False, False ]
                    (List.map isCounterBig [ FfDelay, FfText1In, FfText1Hold, FfText1Out, FfText2In, FfText2Hold, FfText2Out ])
        ]


lastTriggerForSlotTests : Test
lastTriggerForSlotTests =
    describe "lastTriggerForSlot"
        [ test "0 before the slot has ever been triggered (dingKey == slotIndex)" <|
            \_ -> Expect.equal 0 (lastTriggerForSlot 3 3)
        , test "0 when dingKey is less than slotIndex" <|
            \_ -> Expect.equal 0 (lastTriggerForSlot 5 2)
        , test "computes the most recent dingKey that mapped to this slot" <|
            \_ -> Expect.equal 9 (lastTriggerForSlot 0 9)
        ]


randomBoundsTests : Test
randomBoundsTests =
    let
        seeds =
            List.map Random.initialSeed (List.range 0 25)

        dingDelaySamples =
            List.map (\s -> Tuple.first (Random.step dingDelayGen s)) seeds

        fakeFlashPointSamples =
            List.map (\s -> Tuple.first (Random.step (fakeFlashPointGen 100) s)) seeds
    in
    describe "generator bounds (sampled across 26 fixed seeds)"
        [ test "dingDelayGen stays within [minDingDelay, maxDingDelay]" <|
            \_ ->
                dingDelaySamples
                    |> List.all (\delay -> delay >= minDingDelay && delay <= maxDingDelay)
                    |> Expect.equal True
        , test "fakeFlashPointGen stays within [0, total - 1]" <|
            \_ ->
                fakeFlashPointSamples
                    |> List.all (\point -> point >= 0 && point <= 99)
                    |> Expect.equal True
        , test "coinFlipGen produces both outcomes across seeds" <|
            \_ ->
                let
                    coinSamples =
                        List.map (\s -> Tuple.first (Random.step coinFlipGen s)) seeds
                in
                Expect.all
                    [ List.member True >> Expect.equal True
                    , List.member False >> Expect.equal True
                    ]
                    coinSamples
        ]


constantsTests : Test
constantsTests =
    describe "audio/timing constants"
        [ test "iqDingVolume is a valid volume level" <|
            \_ -> Expect.within (Expect.Absolute 0.0001) 0.8 iqDingVolume
        ]
