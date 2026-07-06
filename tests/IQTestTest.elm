module IQTestTest exposing (..)

import Expect
import Game.IQTest
    exposing
        ( FakeFlashPhase(..)
        , dingScheduleGen
        , iqTestInitGen
        , isCounterBig
        , lastTriggerForSlot
        , maxDingDelay
        , minDingDelay
        )
import Random
import Test exposing (Test, describe, test)


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

        dingScheduleSamples =
            List.map (\s -> Tuple.first (Random.step dingScheduleGen s)) seeds

        iqInitSamples =
            List.map (\s -> Tuple.first (Random.step (iqTestInitGen 100) s)) seeds
    in
    describe "generator bounds (sampled across 26 fixed seeds)"
        [ test "dingScheduleGen.delay stays within [minDingDelay, maxDingDelay]" <|
            \_ ->
                dingScheduleSamples
                    |> List.all (\r -> r.delay >= minDingDelay && r.delay <= maxDingDelay)
                    |> Expect.equal True
        , test "iqTestInitGen.fakeFlashPoint stays within [0, total - 1]" <|
            \_ ->
                iqInitSamples
                    |> List.all (\r -> r.fakeFlashPoint >= 0 && r.fakeFlashPoint <= 99)
                    |> Expect.equal True
        , test "iqTestInitGen.delay stays within [minDingDelay, maxDingDelay]" <|
            \_ ->
                iqInitSamples
                    |> List.all (\r -> r.delay >= minDingDelay && r.delay <= maxDingDelay)
                    |> Expect.equal True
        ]
