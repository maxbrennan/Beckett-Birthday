module ServerTest exposing (..)

import Expect
import Json.Decode as Decode
import Json.Encode as Encode
import Server.Protocol exposing (stateIsWin, winAckEnvelope)
import Server.Registry exposing (RegistryEntry, decodeRegistryEntry, encodeRegistryEntry, snapshotForJeopardy)
import Test exposing (Test, describe, test)


screenTag : Encode.Value -> Maybe String
screenTag value =
    Decode.decodeValue (Decode.at [ "savedState", "screen", "tag" ] Decode.string) value
        |> Result.toMaybe


savedStateIsNull : Encode.Value -> Bool
savedStateIsNull value =
    Decode.decodeValue (Decode.field "savedState" (Decode.nullable Decode.value)) value
        == Ok Nothing


makeState : String -> Maybe Encode.Value -> Encode.Value
makeState tag maybeSavedState =
    Encode.object
        [ ( "screen", Encode.object [ ( "tag", Encode.string tag ) ] )
        , ( "pending", Encode.list identity [] )
        , ( "now", Encode.float 1000 )
        , ( "jeopardyPlaying", Encode.bool False )
        , ( "savedState"
          , case maybeSavedState of
                Just s ->
                    s

                Nothing ->
                    Encode.null
          )
        ]


quizSavedState : Encode.Value
quizSavedState =
    Encode.object
        [ ( "screen", Encode.object [ ( "tag", Encode.string "QuizScreen" ) ] )
        , ( "pending", Encode.list identity [] )
        , ( "savedAt", Encode.float 500 )
        , ( "songResumeTime", Encode.null )
        , ( "videoResumeTime", Encode.null )
        ]


screenValue : String -> Encode.Value
screenValue tag =
    Encode.object [ ( "screen", Encode.object [ ( "tag", Encode.string tag ) ] ) ]


wrappedWinValue : String -> Encode.Value
wrappedWinValue wrapperTag =
    Encode.object
        [ ( "screen"
          , Encode.object
                [ ( "tag", Encode.string wrapperTag )
                , ( "nextScreen", Encode.object [ ( "tag", Encode.string "WinScreen" ) ] )
                ]
          )
        ]


ackWinText : Encode.Value -> Maybe String
ackWinText value =
    Decode.decodeValue (Decode.at [ "ack", "winText" ] Decode.string) value
        |> Result.toMaybe


registrySuite : Test
registrySuite =
    describe "RegistryEntry winText codec"
        [ test "round-trips winText through encode/decode" <|
            \_ ->
                { uuid = "u1", filename = "f.dmg", platform = "mac", state = Nothing, pendingStateEdit = False, winText = "claim your reward" }
                    |> encodeRegistryEntry
                    |> Encode.encode 0
                    |> Decode.decodeString decodeRegistryEntry
                    |> Result.map .winText
                    |> Expect.equal (Ok "claim your reward")
        , test "defaults winText to empty for older rows missing the field" <|
            \_ ->
                """{"uuid":"u","filename":"f","platform":"mac","state":null,"pendingStateEdit":false}"""
                    |> Decode.decodeString decodeRegistryEntry
                    |> Result.map .winText
                    |> Expect.equal (Ok "")
        ]


protocolSuite : Test
protocolSuite =
    describe "win detection and delivery"
        [ test "stateIsWin: direct WinScreen" <|
            \_ -> stateIsWin (screenValue "WinScreen") |> Expect.equal True
        , test "stateIsWin: ConfirmingAnswerScreen wrapping WinScreen" <|
            \_ -> stateIsWin (wrappedWinValue "ConfirmingAnswerScreen") |> Expect.equal True
        , test "stateIsWin: CheckingAnswerScreen wrapping WinScreen" <|
            \_ -> stateIsWin (wrappedWinValue "CheckingAnswerScreen") |> Expect.equal True
        , test "stateIsWin: ordinary screen is not a win" <|
            \_ -> stateIsWin (screenValue "QuizScreen") |> Expect.equal False
        , test "stateIsWin: wrapper around a non-win screen is not a win" <|
            \_ ->
                Encode.object
                    [ ( "screen"
                      , Encode.object
                            [ ( "tag", Encode.string "ConfirmingAnswerScreen" )
                            , ( "nextScreen", Encode.object [ ( "tag", Encode.string "BlankScreen" ) ] )
                            ]
                      )
                    ]
                    |> stateIsWin
                    |> Expect.equal False
        , test "winAckEnvelope carries the text under ack.winText" <|
            \_ ->
                winAckEnvelope "hello reward"
                    |> ackWinText
                    |> Expect.equal (Just "hello reward")
        ]


suite : Test
suite =
    describe "snapshotForJeopardy"
        [ test "rejoin mid-game: snapshots the current screen into savedState" <|
            \_ ->
                makeState "QuizScreen" Nothing
                    |> snapshotForJeopardy
                    |> screenTag
                    |> Expect.equal (Just "QuizScreen")
        , test "rejoin already-snapshotted: preserves the existing savedState" <|
            \_ ->
                makeState "BeginScreen" (Just quizSavedState)
                    |> snapshotForJeopardy
                    |> screenTag
                    |> Expect.equal (Just "QuizScreen")
        , test "BeginScreen with no savedState: savedState stays null" <|
            \_ ->
                makeState "BeginScreen" Nothing
                    |> snapshotForJeopardy
                    |> savedStateIsNull
                    |> Expect.equal True
        ]
