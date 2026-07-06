module ServerTest exposing (..)

import Dict
import Expect
import Game.IQTest as IQTest
import Json.Decode as Decode
import Json.Encode as Encode
import Random
import Server
    exposing
        ( ClearOutcome(..)
        , DingKind(..)
        , IqPhase(..)
        , IqTimerState
        , Model
        , Msg(..)
        , advanceOnClear
        , applyCatch
        , classifyDing
        , update
        )
import Server.Distribution exposing (DistStage(..))
import Server.Protocol
    exposing
        ( ClientEnvelope(..)
        , ackEnvelope
        , ackWithUploadTokenEnvelope
        , decodeClientEnvelope
        , distListResultEnvelope
        , iqDingEnvelope
        , stateIsWin
        , winTextEnvelope
        )
import Server.Registry exposing (RegistryEntry, decodeRegistryEntry, encodeRegistryEntry, snapshotForJeopardy)
import Set
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


winTextOf : Encode.Value -> Maybe String
winTextOf value =
    Decode.decodeValue (Decode.at [ "winText", "text" ] Decode.string) value
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
        , test "winTextEnvelope carries the text under winText.text" <|
            \_ ->
                winTextEnvelope "hello reward"
                    |> winTextOf
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



-- ── Admin-op routing (migrated from server/index.js) ────────────────────────


resultIsOk : Result e a -> Bool
resultIsOk r =
    case r of
        Ok _ ->
            True

        Err _ ->
            False


entry : String -> RegistryEntry
entry uuid =
    { uuid = uuid
    , filename = uuid ++ ".dmg"
    , platform = "mac"
    , state = Just (Encode.object [ ( "k", Encode.string "v" ) ])
    , pendingStateEdit = False
    , winText = ""
    }


baseModel : Model
baseModel =
    { connectedPlayers = Dict.empty
    , distClients = Dict.empty
    , registry = [ entry "uuid1", entry "uuid2" ]
    , pendingStateEdits = Set.empty
    , iqTimers = Dict.empty
    , seed = Random.initialSeed 0
    }


registryUuids : Model -> List String
registryUuids model =
    List.map .uuid model.registry


clientEnvelope : String -> List ( String, Encode.Value ) -> Encode.Value
clientEnvelope variant fields =
    Encode.object
        [ ( "payload", Encode.string variant )
        , ( variant, Encode.object fields )
        ]


distUndeployMsg : String -> String -> Msg
distUndeployMsg clientId uuid =
    MessageReceived
        { clientId = clientId
        , payload = clientEnvelope "distUndeploy" [ ( "uuid", Encode.string uuid ) ]
        }


saveMsg : String -> String -> String -> Msg
saveMsg clientId uuid json =
    MessageReceived
        { clientId = clientId
        , payload =
            clientEnvelope "distStateEditSave"
                [ ( "uuid", Encode.string uuid )
                , ( "json", Encode.string json )
                ]
        }


authDone : String -> Bool -> Int -> Msg
authDone clientId success level =
    AuthCompleted { clientId = clientId, success = success, level = level, uuid = "" }


adminOpSuite : Test
adminOpSuite =
    describe "admin-op routing in Server.update"
        [ describe "protocol/codec"
            [ test "decodeClientEnvelope decodes distList" <|
                \_ ->
                    Decode.decodeValue decodeClientEnvelope (clientEnvelope "distList" [])
                        |> Expect.equal (Ok ClientDistList)
            , test "distListResultEnvelope carries uuid/filename/platform and omits state/pendingStateEdit" <|
                \_ ->
                    let
                        encoded =
                            distListResultEnvelope [ entry "uuid1" ]

                        field name =
                            Decode.decodeValue
                                (Decode.at [ "distListResult", "entries" ]
                                    (Decode.index 0 (Decode.field name Decode.string))
                                )
                                encoded

                        hasField name =
                            Decode.decodeValue
                                (Decode.at [ "distListResult", "entries" ]
                                    (Decode.index 0 (Decode.field name Decode.value))
                                )
                                encoded
                                |> resultIsOk
                    in
                    Expect.all
                        [ \_ -> Expect.equal (Ok "uuid1") (field "uuid")
                        , \_ -> Expect.equal (Ok "uuid1.dmg") (field "filename")
                        , \_ -> Expect.equal (Ok "mac") (field "platform")
                        , \_ -> Expect.equal False (hasField "state")
                        , \_ -> Expect.equal False (hasField "pendingStateEdit")
                        ]
                        ()
            , test "ackWithUploadTokenEnvelope carries the mint marker; ackEnvelope does not" <|
                \_ ->
                    let
                        marker env =
                            Decode.decodeValue (Decode.at [ "ack", "mintUploadToken" ] Decode.bool) env
                    in
                    Expect.all
                        [ \_ -> Expect.equal (Ok True) (marker ackWithUploadTokenEnvelope)
                        , \_ -> Expect.equal False (resultIsOk (marker ackEnvelope))
                        ]
                        ()
            ]
        , describe "undeploy"
            [ test "distUndeploy stages AwaitingUndeployAuth without touching the registry" <|
                \_ ->
                    let
                        ( m, _ ) =
                            update (distUndeployMsg "c1" "uuid1") baseModel
                    in
                    Expect.all
                        [ \mm -> Expect.equal (Just (AwaitingUndeployAuth "uuid1")) (Dict.get "c1" mm.distClients)
                        , \mm -> Expect.equal [ "uuid1", "uuid2" ] (registryUuids mm)
                        ]
                        m
            , test "admin auth success removes the build and clears the stage" <|
                \_ ->
                    let
                        staged =
                            { baseModel | distClients = Dict.singleton "c1" (AwaitingUndeployAuth "uuid1") }

                        ( m, _ ) =
                            update (authDone "c1" True 2) staged
                    in
                    Expect.all
                        [ \mm -> Expect.equal [ "uuid2" ] (registryUuids mm)
                        , \mm -> Expect.equal Nothing (Dict.get "c1" mm.distClients)
                        ]
                        m
            , test "failed auth clears the stage and leaves the registry intact" <|
                \_ ->
                    let
                        staged =
                            { baseModel | distClients = Dict.singleton "c1" (AwaitingUndeployAuth "uuid1") }

                        ( m, _ ) =
                            update (authDone "c1" False 0) staged
                    in
                    Expect.all
                        [ \mm -> Expect.equal [ "uuid1", "uuid2" ] (registryUuids mm)
                        , \mm -> Expect.equal Nothing (Dict.get "c1" mm.distClients)
                        ]
                        m
            ]
        , describe "list"
            [ test "admin auth success clears the AwaitingListAuth stage" <|
                \_ ->
                    let
                        staged =
                            { baseModel | distClients = Dict.singleton "c1" AwaitingListAuth }

                        ( m, _ ) =
                            update (authDone "c1" True 2) staged
                    in
                    Expect.equal Nothing (Dict.get "c1" m.distClients)
            , test "failed auth clears the AwaitingListAuth stage" <|
                \_ ->
                    let
                        staged =
                            { baseModel | distClients = Dict.singleton "c1" AwaitingListAuth }

                        ( m, _ ) =
                            update (authDone "c1" False 1) staged
                    in
                    Expect.equal Nothing (Dict.get "c1" m.distClients)
            ]
        , describe "state edit"
            [ test "admin auth success marks pending and enters EditingState" <|
                \_ ->
                    let
                        staged =
                            { baseModel | distClients = Dict.singleton "c1" (AwaitingStateEditAuth "uuid1") }

                        ( m, _ ) =
                            update (authDone "c1" True 2) staged
                    in
                    Expect.all
                        [ \mm -> Expect.equal True (Set.member "uuid1" mm.pendingStateEdits)
                        , \mm -> Expect.equal (Just (EditingState "uuid1")) (Dict.get "c1" mm.distClients)
                        ]
                        m
            , test "save with valid JSON while EditingState clears the stage and pending flag" <|
                \_ ->
                    let
                        staged =
                            { baseModel
                                | distClients = Dict.singleton "c1" (EditingState "uuid1")
                                , pendingStateEdits = Set.singleton "uuid1"
                            }

                        ( m, _ ) =
                            update (saveMsg "c1" "uuid1" "{\"a\":1}") staged
                    in
                    Expect.all
                        [ \mm -> Expect.equal Nothing (Dict.get "c1" mm.distClients)
                        , \mm -> Expect.equal False (Set.member "uuid1" mm.pendingStateEdits)
                        ]
                        m
            , test "save without an EditingState stage is unauthorized and changes nothing" <|
                \_ ->
                    let
                        ( m, _ ) =
                            update (saveMsg "c1" "uuid1" "{}") baseModel
                    in
                    Expect.all
                        [ \mm -> Expect.equal True (Dict.isEmpty mm.distClients)
                        , \mm -> Expect.equal [ "uuid1", "uuid2" ] (registryUuids mm)
                        ]
                        m
            , test "save with invalid JSON clears the stage but leaves the uuid pending (preserved quirk)" <|
                \_ ->
                    let
                        staged =
                            { baseModel
                                | distClients = Dict.singleton "c1" (EditingState "uuid1")
                                , pendingStateEdits = Set.singleton "uuid1"
                            }

                        ( m, _ ) =
                            update (saveMsg "c1" "uuid1" "not json") staged
                    in
                    Expect.all
                        [ \mm -> Expect.equal Nothing (Dict.get "c1" mm.distClients)
                        , \mm -> Expect.equal True (Set.member "uuid1" mm.pendingStateEdits)
                        ]
                        m
            ]
        , describe "register"
            [ test "admin auth success moves AwaitingAuth to AwaitingUpload" <|
                \_ ->
                    let
                        info =
                            { uuid = "uuid3", platform = "mac" }

                        staged =
                            { baseModel | distClients = Dict.singleton "c1" (AwaitingAuth info) }

                        ( m, _ ) =
                            update (authDone "c1" True 2) staged
                    in
                    Expect.equal (Just (AwaitingUpload info)) (Dict.get "c1" m.distClients)
            , test "failed auth clears the AwaitingAuth stage" <|
                \_ ->
                    let
                        info =
                            { uuid = "uuid3", platform = "mac" }

                        staged =
                            { baseModel | distClients = Dict.singleton "c1" (AwaitingAuth info) }

                        ( m, _ ) =
                            update (authDone "c1" False 0) staged
                    in
                    Expect.equal Nothing (Dict.get "c1" m.distClients)
            ]
        ]



-- ── IQ-test server-side timing/scoring ──────────────────────────────────────


-- A baseline mid-test timer state; individual tests override the fields they care about.
iqState : IqTimerState
iqState =
    { epoch = 1
    , phase = IqDingShown
    , countdownRemaining = 0
    , dingCount = 10
    , totalDings = IQTest.iqQuestionCount
    , fakeFlashPoint = 90
    , fakeFlashUsed = False
    , in50PercentPhase = False
    , lastDing = RealDing
    }


advancedState : ClearOutcome -> Maybe IqTimerState
advancedState outcome =
    case outcome of
        Advanced a ->
            Just a.state

        Completed ->
            Nothing


advancedLoud : ClearOutcome -> Maybe Bool
advancedLoud outcome =
    case outcome of
        Advanced a ->
            Just a.startLoud

        Completed ->
            Nothing


iqTimerMsg : String -> String -> Msg
iqTimerMsg clientId variant =
    MessageReceived { clientId = clientId, payload = clientEnvelope variant [] }


iqLogicSuite : Test
iqLogicSuite =
    describe "IQ server-side classify/advance/catch"
        [ describe "classifyDing"
            [ test "the one-time trap fires at fakeFlashPoint" <|
                \_ -> classifyDing False { iqState | dingCount = 90, fakeFlashPoint = 90 } |> Expect.equal TrapFake
            , test "no trap once fakeFlashUsed" <|
                \_ -> classifyDing False { iqState | dingCount = 90, fakeFlashPoint = 90, fakeFlashUsed = True } |> Expect.equal RealDing
            , test "an ordinary index is a real ding" <|
                \_ -> classifyDing False { iqState | dingCount = 10, fakeFlashPoint = 90 } |> Expect.equal RealDing
            , test "50% phase with coin=True yields a phase fake" <|
                \_ -> classifyDing True { iqState | in50PercentPhase = True, fakeFlashUsed = True } |> Expect.equal PhaseFake
            , test "50% phase with coin=False yields a real ding" <|
                \_ -> classifyDing False { iqState | in50PercentPhase = True, fakeFlashUsed = True } |> Expect.equal RealDing
            ]
        , describe "advanceOnClear"
            [ test "a cleared real ding increments dingCount" <|
                \_ ->
                    advanceOnClear { iqState | lastDing = RealDing, dingCount = 10, totalDings = 100 }
                        |> advancedState
                        |> Maybe.map .dingCount
                        |> Expect.equal (Just 11)
            , test "completes when the count reaches the total" <|
                \_ ->
                    advanceOnClear { iqState | lastDing = RealDing, dingCount = 99, totalDings = 100 }
                        |> Expect.equal Completed
            , test "arms the loud gag on the 4th real ding" <|
                \_ ->
                    advanceOnClear { iqState | lastDing = RealDing, dingCount = 3, totalDings = 100 }
                        |> advancedLoud
                        |> Expect.equal (Just True)
            , test "a cleared fake marks the trap used and does not count" <|
                \_ ->
                    let
                        outcome =
                            advanceOnClear { iqState | lastDing = TrapFake, dingCount = 10, fakeFlashUsed = False }
                    in
                    Expect.all
                        [ \o -> advancedState o |> Maybe.map .fakeFlashUsed |> Expect.equal (Just True)
                        , \o -> advancedState o |> Maybe.map .dingCount |> Expect.equal (Just 10)
                        ]
                        outcome
            , test "the punishment phase decrements totalDings without counting" <|
                \_ ->
                    let
                        outcome =
                            advanceOnClear { iqState | lastDing = RealDing, dingCount = 0, totalDings = 200 }
                    in
                    Expect.all
                        [ \o -> advancedState o |> Maybe.map .totalDings |> Expect.equal (Just 199)
                        , \o -> advancedState o |> Maybe.map .dingCount |> Expect.equal (Just 0)
                        ]
                        outcome
            , test "grinding the total down to iqQuestionCount enters the 50% phase" <|
                \_ ->
                    advanceOnClear { iqState | lastDing = RealDing, dingCount = 0, totalDings = IQTest.iqQuestionCount + 1, in50PercentPhase = False }
                        |> advancedState
                        |> Maybe.map .in50PercentPhase
                        |> Expect.equal (Just True)
            ]
        , describe "applyCatch"
            [ test "doubles the count, re-arms punishment, resets progress" <|
                \_ ->
                    let
                        caught =
                            applyCatch { iqState | totalDings = 100, dingCount = 5, fakeFlashUsed = False, in50PercentPhase = True }
                    in
                    Expect.all
                        [ \c -> Expect.equal 200 c.totalDings
                        , \c -> Expect.equal True c.fakeFlashUsed
                        , \c -> Expect.equal False c.in50PercentPhase
                        , \c -> Expect.equal 0 c.dingCount
                        ]
                        caught
            , test "caps the doubling at maxTotalDings" <|
                \_ ->
                    applyCatch { iqState | totalDings = IQTest.maxTotalDings }
                        |> .totalDings
                        |> Expect.equal IQTest.maxTotalDings
            ]
        ]


iqUpdateSuite : Test
iqUpdateSuite =
    describe "IQ-test message routing in Server.update"
        [ test "decodeClientEnvelope decodes the payload-less IQ client messages" <|
            \_ ->
                Expect.all
                    [ \_ -> Expect.equal (Ok ClientIqStartCountdown) (Decode.decodeValue decodeClientEnvelope (clientEnvelope "iqStartCountdown" []))
                    , \_ -> Expect.equal (Ok ClientIqReadyForDing) (Decode.decodeValue decodeClientEnvelope (clientEnvelope "iqReadyForDing" []))
                    , \_ -> Expect.equal (Ok ClientIqCaught) (Decode.decodeValue decodeClientEnvelope (clientEnvelope "iqCaught" []))
                    ]
                    ()
        , test "iqDingEnvelope round-trips fake/trap/dingCount/totalDings" <|
            \_ ->
                let
                    env =
                        iqDingEnvelope { fake = True, trap = True, dingCount = 7, totalDings = 200 }

                    intAt name =
                        Decode.decodeValue (Decode.at [ "iqDing", name ] Decode.int) env

                    boolAt name =
                        Decode.decodeValue (Decode.at [ "iqDing", name ] Decode.bool) env
                in
                Expect.all
                    [ \_ -> Expect.equal (Ok True) (boolAt "fake")
                    , \_ -> Expect.equal (Ok True) (boolAt "trap")
                    , \_ -> Expect.equal (Ok 7) (intAt "dingCount")
                    , \_ -> Expect.equal (Ok 200) (intAt "totalDings")
                    ]
                    ()
        , test "iqStartCountdown initializes the server's own count at iqQuestionCount" <|
            \_ ->
                let
                    ( m, _ ) =
                        update (iqTimerMsg "c1" "iqStartCountdown") baseModel
                in
                Dict.get "c1" m.iqTimers
                    |> Maybe.map (\s -> ( s.totalDings, s.phase ))
                    |> Expect.equal (Just ( IQTest.iqQuestionCount, IqCounting ))
        , test "iqCaught doubles the server's own count and goes idle" <|
            \_ ->
                let
                    staged =
                        { baseModel
                            | iqTimers = Dict.singleton "c1" { iqState | totalDings = 100, phase = IqDingShown, lastDing = TrapFake }
                        }

                    ( m, _ ) =
                        update (iqTimerMsg "c1" "iqCaught") staged
                in
                Dict.get "c1" m.iqTimers
                    |> Maybe.map (\s -> ( s.totalDings, s.phase ))
                    |> Expect.equal (Just ( 200, IqIdle ))
        , test "iqCaught is ignored unless a trap fake is outstanding" <|
            \_ ->
                let
                    staged =
                        { baseModel
                            | iqTimers = Dict.singleton "c1" { iqState | totalDings = 100, phase = IqDingShown, lastDing = PhaseFake }
                        }

                    ( m, _ ) =
                        update (iqTimerMsg "c1" "iqCaught") staged
                in
                Dict.get "c1" m.iqTimers
                    |> Maybe.map .totalDings
                    |> Expect.equal (Just 100)
        , test "a stale DingReady (wrong epoch) is ignored" <|
            \_ ->
                let
                    staged =
                        { baseModel
                            | iqTimers = Dict.singleton "c1" { iqState | epoch = 5, phase = IqDingScheduled }
                        }

                    ( m, _ ) =
                        update (DingReady { clientId = "c1", epoch = 4 }) staged
                in
                Dict.get "c1" m.iqTimers
                    |> Maybe.map .phase
                    |> Expect.equal (Just IqDingScheduled)
        ]
