module ServerTest exposing (..)

import Expect
import Json.Decode as Decode
import Json.Encode as Encode
import Server exposing (snapshotForJeopardy)
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


suite : Test
suite =
    describe "snapshotForJeopardy"
        [ test "first disconnect: snapshots the current screen into savedState" <|
            \_ ->
                makeState "QuizScreen" Nothing
                    |> snapshotForJeopardy
                    |> screenTag
                    |> Expect.equal (Just "QuizScreen")
        , test "reconnect-then-disconnect: preserves the existing savedState" <|
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
