module SyncTest exposing (..)

import Expect
import Json.Decode as Decode
import Json.Encode as Encode
import Sync
    exposing
        ( ServerEnvelope(..)
        , clientStateEnvelope
        , decodeModel
        , decodeScreen
        , decodeServerEnvelope
        , encodeModel
        , encodeScreen
        , stateRequestEnvelope
        )
import Test exposing (Test, describe, test)
import Types exposing (Model, Screen(..))


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
        , test "myUuid/wsUrl/questions are NOT persisted — decodeModel always resets them" <|
            \_ ->
                case decoded of
                    Ok m ->
                        Expect.equal ( Nothing, "", [] ) ( m.myUuid, m.wsUrl, m.questions )

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
        , test "ack" <|
            \_ ->
                Decode.decodeString decodeServerEnvelope """{"payload":"ack"}"""
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
                        }
                in
                clientStateEnvelope model
                    |> Decode.decodeValue (Decode.field "payload" Decode.string)
                    |> Expect.equal (Ok "stateUpdate")
        ]
