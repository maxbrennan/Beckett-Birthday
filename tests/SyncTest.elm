module SyncTest exposing (..)

import Expect
import Game.IQTest exposing (FakeFlashPhase(..))
import Json.Decode as Decode
import Json.Encode as Encode
import Sync
    exposing
        ( ServerEnvelope(..)
        , clientStateEnvelope
        , decodeFakeFlashPhase
        , decodeMsg
        , decodeModel
        , decodePausedState
        , decodeScreen
        , decodeServerEnvelope
        , encodeFakeFlashPhase
        , encodeModel
        , encodeMsg
        , encodePausedState
        , encodeScreen
        , iqCaughtEnvelope
        , iqReadyForDingEnvelope
        , iqResumeEnvelope
        , iqStartCountdownEnvelope
        , quizAdvancedEnvelope
        , quizAnswerSubmittedEnvelope
        , stateRequestEnvelope
        )
import Test exposing (Test, describe, test)
import Types exposing (Model, Msg(..), PausedState, Screen(..))


roundTripScreen : Screen -> Screen
roundTripScreen scr =
    encodeScreen scr
        |> Decode.decodeValue decodeScreen
        |> Result.withDefault WsErrorScreen


screenRoundTripTests : Test
screenRoundTripTests =
    describe "encodeScreen / decodeScreen round-trip"
        [ test "BeginScreen" <|
            \_ -> Expect.equal BeginScreen (roundTripScreen BeginScreen)
        , test "BlankScreen carries its index" <|
            \_ -> Expect.equal (BlankScreen 3) (roundTripScreen (BlankScreen 3))
        , test "VideoScreen carries index and filename" <|
            \_ -> Expect.equal (VideoScreen 2 "video.mp4") (roundTripScreen (VideoScreen 2 "video.mp4"))
        , test "QuestionScreen carries index and answer text" <|
            \_ -> Expect.equal (QuestionScreen 1 "answer") (roundTripScreen (QuestionScreen 1 "answer"))
        , test "TimedOutScreen" <|
            \_ -> Expect.equal TimedOutScreen (roundTripScreen TimedOutScreen)
        , test "CheckingAnswerScreen nests the next screen" <|
            \_ -> Expect.equal (CheckingAnswerScreen (QuestionScreen 4 "x")) (roundTripScreen (CheckingAnswerScreen (QuestionScreen 4 "x")))
        , test "WinScreen deliberately drops its text on encode (never persisted)" <|
            \_ -> Expect.equal (WinScreen "") (roundTripScreen (WinScreen "top secret win text"))
        , test "WsConnectingScreen" <|
            \_ -> Expect.equal WsConnectingScreen (roundTripScreen WsConnectingScreen)
        , test "WsErrorScreen" <|
            \_ -> Expect.equal WsErrorScreen (roundTripScreen WsErrorScreen)
        , test "WsLoadingScreen" <|
            \_ -> Expect.equal WsLoadingScreen (roundTripScreen WsLoadingScreen)
        , test "WrongAnswerScreen carries its index but deliberately drops the reveal text on encode (never persisted)" <|
            \_ -> Expect.equal (WrongAnswerScreen 5 "") (roundTripScreen (WrongAnswerScreen 5 "top secret answer"))
        , test "IQTestScreen carries its state" <|
            \_ -> Expect.equal (IQTestScreen { questionIdx = 1, totalDings = 100 }) (roundTripScreen (IQTestScreen { questionIdx = 1, totalDings = 100 }))
        , test "IQTestCountdownScreen carries its state" <|
            \_ ->
                Expect.equal
                    (IQTestCountdownScreen { questionIdx = 1, totalDings = 100, countdown = 3 })
                    (roundTripScreen (IQTestCountdownScreen { questionIdx = 1, totalDings = 100, countdown = 3 }))
        , test "IQTestActiveScreen carries its state" <|
            \_ ->
                let
                    state =
                        { questionIdx = 1, dingCount = 2, totalDings = 100, isFlashing = True, dingActive = False, fakeFlashActive = True, fakeIsTrap = False, loudPlaying = True }
                in
                Expect.equal (IQTestActiveScreen state) (roundTripScreen (IQTestActiveScreen state))
        , test "FakeFlashCaughtScreen carries its state" <|
            \_ ->
                let
                    state =
                        { questionIdx = 1, originalTotal = 100, displayNumerator = 3, displayDenominator = 100, phase = FfText1Hold }
                in
                Expect.equal (FakeFlashCaughtScreen state) (roundTripScreen (FakeFlashCaughtScreen state))
        , test "ConfirmingAnswerScreen nests the next screen" <|
            \_ -> Expect.equal (ConfirmingAnswerScreen (BlankScreen 4)) (roundTripScreen (ConfirmingAnswerScreen (BlankScreen 4)))
        , test "an unrecognized tag fails to decode" <|
            \_ ->
                Decode.decodeString decodeScreen """{"tag":"NotAScreen"}"""
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        ]


fakeFlashPhaseRoundTripTests : Test
fakeFlashPhaseRoundTripTests =
    let
        roundTrip phase =
            encodeFakeFlashPhase phase
                |> Decode.decodeValue decodeFakeFlashPhase
    in
    describe "encodeFakeFlashPhase / decodeFakeFlashPhase round-trip"
        [ test "round-trips every phase" <|
            \_ ->
                [ FfDelay, FfText1In, FfText1Hold, FfText1Out, FfText2In, FfText2Hold, FfText2Out, FfCounterIn, FfTickNumerator, FfTickDelay, FfTickDenominator, FfCounterOut ]
                    |> List.map roundTrip
                    |> Expect.equal
                        (List.map Ok [ FfDelay, FfText1In, FfText1Hold, FfText1Out, FfText2In, FfText2Hold, FfText2Out, FfCounterIn, FfTickNumerator, FfTickDelay, FfTickDenominator, FfCounterOut ])
        , test "rejects an unknown phase string" <|
            \_ ->
                Decode.decodeValue decodeFakeFlashPhase (Encode.string "NotAPhase")
                    |> Result.toMaybe
                    |> Expect.equal Nothing
        ]


msgRoundTripTests : Test
msgRoundTripTests =
    let
        roundTrip msg =
            encodeMsg msg
                |> Decode.decodeValue decodeMsg
    in
    describe "encodeMsg / decodeMsg round-trip"
        [ test "round-trips every explicitly-encoded Msg variant" <|
            \_ ->
                let
                    msgs =
                        [ Tick 100
                        , PlaySong 2
                        , ShowQuestion 2
                        , TrackEnded "song.mp3"
                        , DingFlashEnd
                        , DingWindowExpired
                        , FakeFlashWindowExpired
                        , FakeFlashCounterTick
                        , FakeFlashNextPhase
                        , StartLoudMusic
                        , WsReconnect
                        ]
                in
                List.map roundTrip msgs |> Expect.equal (List.map Ok msgs)
        , test "a Msg with no dedicated encoding falls back to NoOp" <|
            \_ -> roundTrip AnswerSubmitted |> Expect.equal (Ok NoOp)
        , test "decodeMsg maps an unrecognized tag to NoOp" <|
            \_ -> Decode.decodeString decodeMsg """{"tag":"SomethingUnknown"}""" |> Expect.equal (Ok NoOp)
        ]


pausedStateRoundTripTests : Test
pausedStateRoundTripTests =
    describe "encodePausedState / decodePausedState round-trip"
        [ test "round-trips a paused state with pending events and resume times" <|
            \_ ->
                let
                    saved : PausedState
                    saved =
                        { screen = BlankScreen 1
                        , pending = [ { fireAt = 1500, msg = ShowQuestion 1 }, { fireAt = 2000, msg = PlaySong 2 } ]
                        , savedAt = 1000
                        , songResumeTime = Just 12.5
                        , videoResumeTime = Just 3.5
                        }
                in
                encodePausedState saved
                    |> Decode.decodeValue decodePausedState
                    |> Expect.equal (Ok saved)
        , test "round-trips Nothing resume times" <|
            \_ ->
                let
                    saved : PausedState
                    saved =
                        { screen = BeginScreen, pending = [], savedAt = 0, songResumeTime = Nothing, videoResumeTime = Nothing }
                in
                encodePausedState saved
                    |> Decode.decodeValue decodePausedState
                    |> Expect.equal (Ok saved)
        ]


modelWithSavedStateRoundTripTests : Test
modelWithSavedStateRoundTripTests =
    let
        model : Model
        model =
            { screen = BlankScreen 0
            , jeopardyPlaying = False
            , now = 500
            , pending = []
            , savedState = Just { screen = VideoScreen 0 "v.mp4", pending = [], savedAt = 400, songResumeTime = Nothing, videoResumeTime = Just 1.5 }
            , dingKey = 0
            , pendingStartTime = Nothing
            , wsClientId = Nothing
            , timerEndsAt = 0
            , myUuid = Nothing
            , wsUrl = ""
            , questions = []
            , awaitingAnswerResult = False
            }
    in
    describe "encodeModel / decodeModel round-trip with a saved state"
        [ test "round-trips savedState" <|
            \_ ->
                encodeModel model
                    |> Decode.decodeValue decodeModel
                    |> Result.map .savedState
                    |> Expect.equal (Ok model.savedState)
        ]


iqEnvelopeBuilderTests : Test
iqEnvelopeBuilderTests =
    describe "IQ-test client->server envelope builders"
        [ test "iqStartCountdownEnvelope" <|
            \_ -> Encode.encode 0 iqStartCountdownEnvelope |> Expect.equal """{"payload":"iqStartCountdown","iqStartCountdown":{}}"""
        , test "iqReadyForDingEnvelope" <|
            \_ -> Encode.encode 0 iqReadyForDingEnvelope |> Expect.equal """{"payload":"iqReadyForDing","iqReadyForDing":{}}"""
        , test "iqCaughtEnvelope" <|
            \_ -> Encode.encode 0 iqCaughtEnvelope |> Expect.equal """{"payload":"iqCaught","iqCaught":{}}"""
        , test "iqResumeEnvelope" <|
            \_ -> Encode.encode 0 iqResumeEnvelope |> Expect.equal """{"payload":"iqResume","iqResume":{}}"""
        ]


quizEnvelopeBuilderTests : Test
quizEnvelopeBuilderTests =
    describe "quiz client->server envelope builders"
        [ test "quizAdvancedEnvelope carries the idx" <|
            \_ -> Encode.encode 0 (quizAdvancedEnvelope 3) |> Expect.equal """{"payload":"quizAdvanced","quizAdvanced":{"idx":3}}"""
        , test "quizAnswerSubmittedEnvelope carries the idx and answer" <|
            \_ ->
                Encode.encode 0 (quizAnswerSubmittedEnvelope { idx = 2, answer = "Alpha" })
                    |> Expect.equal """{"payload":"quizAnswerSubmitted","quizAnswerSubmitted":{"idx":2,"answer":"Alpha"}}"""
        ]


modelRoundTripTests : Test
modelRoundTripTests =
    let
        model : Model
        model =
            { screen = BlankScreen 2
            , jeopardyPlaying = True
            , now = 12345
            , pending = []
            , savedState = Nothing
            , dingKey = 7
            , pendingStartTime = Just 999
            , wsClientId = Just "client-1"
            , timerEndsAt = 54321
            , myUuid = Just "should-not-round-trip"
            , wsUrl = "wss://example.com"
            , questions = []
            , awaitingAnswerResult = True
            }

        decoded =
            encodeModel model
                |> Decode.decodeValue decodeModel
    in
    describe "encodeModel / decodeModel round-trip"
        [ test "round-trips the persisted fields" <|
            \_ ->
                case decoded of
                    Ok m ->
                        Expect.equal
                            { screen = model.screen, jeopardyPlaying = model.jeopardyPlaying, now = model.now, dingKey = model.dingKey, pendingStartTime = model.pendingStartTime, wsClientId = model.wsClientId, timerEndsAt = model.timerEndsAt }
                            { screen = m.screen, jeopardyPlaying = m.jeopardyPlaying, now = m.now, dingKey = m.dingKey, pendingStartTime = m.pendingStartTime, wsClientId = m.wsClientId, timerEndsAt = m.timerEndsAt }

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        , test "myUuid/wsUrl/questions/awaitingAnswerResult are NOT persisted — decodeModel always resets them" <|
            \_ ->
                case decoded of
                    Ok m ->
                        Expect.equal
                            { myUuid = Nothing, wsUrl = "", questions = [], awaitingAnswerResult = False }
                            { myUuid = m.myUuid, wsUrl = m.wsUrl, questions = m.questions, awaitingAnswerResult = m.awaitingAnswerResult }

                    Err err ->
                        Expect.fail (Decode.errorToString err)
        ]


serverEnvelopeTests : Test
serverEnvelopeTests =
    describe "decodeServerEnvelope"
        [ test "stateUpdate carries the nested json string" <|
            \_ ->
                Decode.decodeString decodeServerEnvelope """{"payload":"stateUpdate","stateUpdate":{"json":"{\\"a\\":1}"}}"""
                    |> Expect.equal (Ok (ServerStateUpdate "{\"a\":1}"))
        , test "stateUpdateAck" <|
            \_ ->
                Decode.decodeString decodeServerEnvelope """{"payload":"stateUpdateAck"}"""
                    |> Expect.equal (Ok ServerAck)
        , test "winText carries the text" <|
            \_ ->
                Decode.decodeString decodeServerEnvelope """{"payload":"winText","winText":{"text":"congrats"}}"""
                    |> Expect.equal (Ok (ServerWinText "congrats"))
        , test "stateRequestRejected carries the reason" <|
            \_ ->
                Decode.decodeString decodeServerEnvelope """{"payload":"stateRequestRejected","stateRequestRejected":{"reason":"locked"}}"""
                    |> Expect.equal (Ok (ServerRejected "locked"))
        , test "unknown payload maps to ServerUnknown" <|
            \_ ->
                Decode.decodeString decodeServerEnvelope """{"payload":"somethingElse"}"""
                    |> Expect.equal (Ok ServerUnknown)
        , test "authChallenge" <|
            \_ ->
                Decode.decodeString decodeServerEnvelope """{"payload":"authChallenge"}"""
                    |> Expect.equal (Ok ServerAuth)
        , test "authResult" <|
            \_ ->
                Decode.decodeString decodeServerEnvelope """{"payload":"authResult"}"""
                    |> Expect.equal (Ok ServerAuth)
        , test "iqCountdownTick carries the remaining count" <|
            \_ ->
                Decode.decodeString decodeServerEnvelope """{"payload":"iqCountdownTick","iqCountdownTick":{"remaining":3}}"""
                    |> Expect.equal (Ok (ServerIqCountdownTick 3))
        , test "iqCountdownComplete" <|
            \_ ->
                Decode.decodeString decodeServerEnvelope """{"payload":"iqCountdownComplete"}"""
                    |> Expect.equal (Ok ServerIqCountdownComplete)
        , test "iqDing with all fields present" <|
            \_ ->
                Decode.decodeString decodeServerEnvelope """{"payload":"iqDing","iqDing":{"fake":true,"trap":true,"dingCount":5,"totalDings":100}}"""
                    |> Expect.equal (Ok (ServerIqDing { fake = True, trap = True, dingCount = 5, totalDings = 100 }))
        , test "iqDing defaults trap/dingCount/totalDings to false/0 when protobufjs omits them" <|
            \_ ->
                Decode.decodeString decodeServerEnvelope """{"payload":"iqDing","iqDing":{"fake":false}}"""
                    |> Expect.equal (Ok (ServerIqDing { fake = False, trap = False, dingCount = 0, totalDings = 0 }))
        , test "iqStartLoud" <|
            \_ ->
                Decode.decodeString decodeServerEnvelope """{"payload":"iqStartLoud"}"""
                    |> Expect.equal (Ok ServerIqStartLoud)
        , test "iqTestComplete" <|
            \_ ->
                Decode.decodeString decodeServerEnvelope """{"payload":"iqTestComplete"}"""
                    |> Expect.equal (Ok ServerIqTestComplete)
        , test "quizAnswerResult with all fields present" <|
            \_ ->
                Decode.decodeString decodeServerEnvelope """{"payload":"quizAnswerResult","quizAnswerResult":{"idx":2,"correct":false,"revealAnswer":"Alpha"}}"""
                    |> Expect.equal (Ok (ServerQuizAnswerResult { idx = 2, correct = False, revealAnswer = "Alpha" }))
        , test "quizAnswerResult defaults correct/revealAnswer to false/\"\" when protobufjs omits them" <|
            \_ ->
                Decode.decodeString decodeServerEnvelope """{"payload":"quizAnswerResult","quizAnswerResult":{"idx":0}}"""
                    |> Expect.equal (Ok (ServerQuizAnswerResult { idx = 0, correct = False, revealAnswer = "" }))
        ]


envelopeBuilderTests : Test
envelopeBuilderTests =
    describe "outgoing envelope builders"
        [ test "stateRequestEnvelope carries the uuid" <|
            \_ ->
                stateRequestEnvelope "abc-123"
                    |> Encode.encode 0
                    |> Expect.equal """{"payload":"stateRequest","stateRequest":{"uuid":"abc-123"}}"""
        , test "clientStateEnvelope wraps an encoded model as a stateUpdate JSON string" <|
            \_ ->
                let
                    model : Model
                    model =
                        { screen = BeginScreen
                        , jeopardyPlaying = False
                        , now = 0
                        , pending = []
                        , savedState = Nothing
                        , dingKey = 0
                        , pendingStartTime = Nothing
                        , wsClientId = Nothing
                        , timerEndsAt = 0
                        , myUuid = Nothing
                        , wsUrl = ""
                        , questions = []
                        , awaitingAnswerResult = False
                        }
                in
                clientStateEnvelope model
                    |> Decode.decodeValue (Decode.field "payload" Decode.string)
                    |> Expect.equal (Ok "stateUpdate")
        ]
