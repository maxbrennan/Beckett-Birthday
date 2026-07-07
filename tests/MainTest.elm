module MainTest exposing (..)

import Expect
import Main exposing (update)
import Test exposing (Test, describe, test)
import Types exposing (Model, Msg(..), Screen(..))


baseModel : Model
baseModel =
    { screen = BeginScreen
    , jeopardyPlaying = False
    , now = 1000
    , pending = []
    , savedState = Nothing
    , dingKey = 0
    , pendingStartTime = Nothing
    , wsClientId = Just "old-ws-id"
    , timerEndsAt = 0
    , myUuid = Just "uuid1"
    , wsUrl = "wss://example.test"
    , questions = []
    }


pendingReconnectFireAt : Model -> Maybe Float
pendingReconnectFireAt model =
    model.pending
        |> List.filter (\e -> e.msg == WsReconnect)
        |> List.map .fireAt
        |> List.head


suite : Test
suite =
    describe "WsDisconnected reconnect throttling (issue #51)"
        [ test "disconnecting from an active screen throttles the reconnect via scheduleReconnect" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDisconnected "closed") { baseModel | screen = BeginScreen }
                in
                Expect.all
                    [ \m -> m.screen |> Expect.equal WsConnectingScreen
                    , \m -> m.wsClientId |> Expect.equal Nothing
                    , \m -> pendingReconnectFireAt m |> Expect.equal (Just (baseModel.now + 3000))
                    ]
                    result
        , test "disconnecting from WsErrorScreen also throttles the reconnect, instead of retrying immediately" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDisconnected "closed") { baseModel | screen = WsErrorScreen }
                in
                Expect.all
                    [ \m -> m.screen |> Expect.equal WsConnectingScreen
                    , \m -> m.wsClientId |> Expect.equal Nothing
                    , \m -> pendingReconnectFireAt m |> Expect.equal (Just (baseModel.now + 3000))
                    ]
                    result
        , test "disconnecting while already on WsConnectingScreen dedupes to a single pending reconnect" <|
            \_ ->
                let
                    ( result, _ ) =
                        update (WsDisconnected "closed") { baseModel | screen = WsConnectingScreen }
                in
                result.pending
                    |> List.filter (\e -> e.msg == WsReconnect)
                    |> List.length
                    |> Expect.equal 1
        ]
