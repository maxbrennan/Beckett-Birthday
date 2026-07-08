module IQTestTest exposing (..)

import Expect
import Game.IQTest
    exposing
        ( FakeFlashPhase(..)
        , dingDelayGen
        , fakeFlashPointGen
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
        ]
