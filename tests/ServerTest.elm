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
        , EditedIqScreen(..)
        , IqPhase(..)
        , IqTimerState
        , Model
        , Msg(..)
        , advanceOnClear
        , applyCatch
        , classifyDing
        , clearIqTimer
        , decodeEditedIqScreen
        , decodeIqTimerStateFull
        , deriveIqScreen
        , encodeIqTimerStateFull
        , extractQuestionIdx
        , persistIqTimerInRegistry
        , reconcileIqTimerAfterEdit
        , setIqTimer
        , update
        )
import Server.Distribution exposing (DistStage(..))
import Server.Protocol
    exposing
        ( ClientEnvelope(..)
        , decodeClientEnvelope
        , distListResultEnvelope
        , iqDingEnvelope
        , distRegisterAckEnvelope
        , stateIsWin
        , stateUpdateAckEnvelope
        , winTextEnvelope
        )
import Server.Registry exposing (RegistryEntry, decodeRegistryEntry, encodeRegistryEntry, snapshotForJeopardy)
import Sync exposing (decodeIQTestCountdownState, decodeIQTestState)
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
                { uuid = "u1", filename = "f.dmg", platform = "mac", state = Nothing, pendingStateEdit = False, winText = "claim your reward", iqTimer = Nothing }
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
    , iqTimer = Nothing
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
            , test "distRegisterAckEnvelope carries the mint marker; stateUpdateAckEnvelope does not" <|
                \_ ->
                    let
                        marker env =
                            Decode.decodeValue (Decode.at [ "distRegisterAck", "mintUploadToken" ] Decode.bool) env
                    in
                    Expect.all
                        [ \_ -> Expect.equal (Ok True) (marker distRegisterAckEnvelope)
                        , \_ -> Expect.equal False (resultIsOk (marker stateUpdateAckEnvelope))
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
    , questionIdx = 0
    , countdownRemaining = 0
    , dingCount = 10
    , totalDings = IQTest.iqQuestionCount
    , fakeFlashPoint = 90
    , fakeFlashUsed = False
    , in50PercentPhase = False
    , lastDing = RealDing
    , dingDelay = Nothing
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
            , test "full punishment cycle: denominator grinds down to iqQuestionCount, then the numerator counts up" <|
                \_ ->
                    let
                        doubled =
                            { iqState | lastDing = RealDing, dingCount = 0, totalDings = IQTest.iqQuestionCount + 3, in50PercentPhase = False }

                        clear s =
                            case advanceOnClear s of
                                Advanced a ->
                                    a.state

                                Completed ->
                                    s

                        afterThreeClears =
                            List.foldl (\_ s -> clear s) doubled (List.range 1 3)

                        afterFourthClear =
                            clear afterThreeClears
                    in
                    Expect.all
                        [ \_ -> Expect.equal IQTest.iqQuestionCount afterThreeClears.totalDings
                        , \_ -> Expect.equal 0 afterThreeClears.dingCount
                        , \_ -> Expect.equal True afterThreeClears.in50PercentPhase
                        , \_ -> Expect.equal IQTest.iqQuestionCount afterFourthClear.totalDings
                        , \_ -> Expect.equal 1 afterFourthClear.dingCount
                        ]
                        ()
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
                    connected =
                        { baseModel | connectedPlayers = Dict.singleton "uuid1" "c1" }

                    ( m, _ ) =
                        update (iqTimerMsg "c1" "iqStartCountdown") connected
                in
                Dict.get "uuid1" m.iqTimers
                    |> Maybe.map (\s -> ( s.totalDings, s.phase ))
                    |> Expect.equal (Just ( IQTest.iqQuestionCount, IqCounting ))
        , test "iqReadyForDing from IqAwaitingReady rolls and stores a dingDelay in range" <|
            \_ ->
                let
                    staged =
                        { baseModel
                            | connectedPlayers = Dict.singleton "uuid1" "c1"
                            , iqTimers = Dict.singleton "uuid1" { iqState | phase = IqAwaitingReady, dingDelay = Nothing }
                        }

                    ( m, _ ) =
                        update (iqTimerMsg "c1" "iqReadyForDing") staged

                    delay =
                        Dict.get "uuid1" m.iqTimers |> Maybe.andThen .dingDelay
                in
                Expect.all
                    [ \_ -> Dict.get "uuid1" m.iqTimers |> Maybe.map .phase |> Expect.equal (Just IqDingScheduled)
                    , \_ -> delay |> Maybe.map (\d -> d >= IQTest.minDingDelay && d <= IQTest.maxDingDelay) |> Expect.equal (Just True)
                    ]
                    ()
        , test "iqCaught doubles the server's own count and goes idle" <|
            \_ ->
                let
                    staged =
                        { baseModel
                            | connectedPlayers = Dict.singleton "uuid1" "c1"
                            , iqTimers = Dict.singleton "uuid1" { iqState | totalDings = 100, phase = IqDingShown, lastDing = TrapFake }
                        }

                    ( m, _ ) =
                        update (iqTimerMsg "c1" "iqCaught") staged
                in
                Dict.get "uuid1" m.iqTimers
                    |> Maybe.map (\s -> ( s.totalDings, s.phase ))
                    |> Expect.equal (Just ( 200, IqIdle ))
        , test "iqCaught is ignored unless a trap fake is outstanding" <|
            \_ ->
                let
                    staged =
                        { baseModel
                            | connectedPlayers = Dict.singleton "uuid1" "c1"
                            , iqTimers = Dict.singleton "uuid1" { iqState | totalDings = 100, phase = IqDingShown, lastDing = PhaseFake }
                        }

                    ( m, _ ) =
                        update (iqTimerMsg "c1" "iqCaught") staged
                in
                Dict.get "uuid1" m.iqTimers
                    |> Maybe.map .totalDings
                    |> Expect.equal (Just 100)
        , test "iqCaught with no clientId->uuid mapping is a no-op" <|
            \_ ->
                let
                    staged =
                        { baseModel | iqTimers = Dict.singleton "uuid1" { iqState | totalDings = 100, phase = IqDingShown, lastDing = TrapFake } }

                    ( m, _ ) =
                        update (iqTimerMsg "c1" "iqCaught") staged
                in
                Dict.get "uuid1" m.iqTimers
                    |> Maybe.map .totalDings
                    |> Expect.equal (Just 100)
        , test "a stale DingReady (wrong epoch) is ignored" <|
            \_ ->
                let
                    staged =
                        { baseModel
                            | iqTimers = Dict.singleton "uuid1" { iqState | epoch = 5, phase = IqDingScheduled }
                        }

                    ( m, _ ) =
                        update (DingReady { uuid = "uuid1", epoch = 4 }) staged
                in
                Dict.get "uuid1" m.iqTimers
                    |> Maybe.map .phase
                    |> Expect.equal (Just IqDingScheduled)
        , test "a disconnect pauses (bumps epoch, keeps state) rather than dropping the IQ timer" <|
            \_ ->
                let
                    staged =
                        { baseModel
                            | connectedPlayers = Dict.singleton "uuid1" "c1"
                            , iqTimers = Dict.singleton "uuid1" { iqState | epoch = 1, dingCount = 10, phase = IqDingScheduled, dingDelay = Just 5000 }
                        }

                    ( m, _ ) =
                        update (ClientDisconnected "c1") staged
                in
                Dict.get "uuid1" m.iqTimers
                    |> Expect.equal (Just { iqState | epoch = 2, dingCount = 10, phase = IqDingScheduled, dingDelay = Just 5000 })
        , test "a disconnect while a ding is shown and unresolved rewinds it to IqDingScheduled, preserving dingDelay" <|
            \_ ->
                let
                    staged =
                        { baseModel
                            | connectedPlayers = Dict.singleton "uuid1" "c1"
                            , iqTimers = Dict.singleton "uuid1" { iqState | epoch = 1, dingCount = 10, phase = IqDingShown, dingDelay = Just 11000 }
                        }

                    ( m, _ ) =
                        update (ClientDisconnected "c1") staged
                in
                Dict.get "uuid1" m.iqTimers
                    |> Expect.equal (Just { iqState | epoch = 2, dingCount = 10, phase = IqDingScheduled, dingDelay = Just 11000 })
        , test "a paused CountdownStep fire (stale epoch after disconnect) is a no-op" <|
            \_ ->
                let
                    staged =
                        { baseModel
                            | connectedPlayers = Dict.singleton "uuid1" "c1"
                            , iqTimers = Dict.singleton "uuid1" { iqState | epoch = 1, phase = IqCounting, countdownRemaining = 42 }
                        }

                    ( disconnected, _ ) =
                        update (ClientDisconnected "c1") staged

                    ( m, _ ) =
                        update (CountdownStep { uuid = "uuid1", epoch = 1 }) disconnected
                in
                Dict.get "uuid1" m.iqTimers
                    |> Maybe.map .countdownRemaining
                    |> Expect.equal (Just 42)
        , test "iqResume re-arms a paused mid-countdown timer and resends the current tick" <|
            \_ ->
                let
                    staged =
                        { baseModel
                            | connectedPlayers = Dict.singleton "uuid1" "c1"
                            , iqTimers = Dict.singleton "uuid1" { iqState | epoch = 2, phase = IqCounting, countdownRemaining = 42 }
                        }

                    ( m, _ ) =
                        update (iqTimerMsg "c1" "iqResume") staged
                in
                Dict.get "uuid1" m.iqTimers
                    |> Maybe.map (\s -> ( s.countdownRemaining, s.phase ))
                    |> Expect.equal (Just ( 42, IqCounting ))
        , test "iqResume on a phase with nothing to resume (IqIdle) is a no-op" <|
            \_ ->
                let
                    staged =
                        { baseModel
                            | connectedPlayers = Dict.singleton "uuid1" "c1"
                            , iqTimers = Dict.singleton "uuid1" { iqState | phase = IqIdle, totalDings = 200 }
                        }

                    ( m, _ ) =
                        update (iqTimerMsg "c1" "iqResume") staged
                in
                Dict.get "uuid1" m.iqTimers
                    |> Expect.equal (Just { iqState | phase = IqIdle, totalDings = 200 })
        , test "iqResume on IqDingScheduled with a preserved dingDelay replays it without drawing a new random delay" <|
            \_ ->
                let
                    staged =
                        { baseModel
                            | connectedPlayers = Dict.singleton "uuid1" "c1"
                            , iqTimers = Dict.singleton "uuid1" { iqState | phase = IqDingScheduled, dingDelay = Just 9000 }
                        }

                    ( m, _ ) =
                        update (iqTimerMsg "c1" "iqResume") staged
                in
                Expect.all
                    [ \_ -> Dict.get "uuid1" m.iqTimers |> Maybe.map .dingDelay |> Expect.equal (Just (Just 9000))
                    , \_ -> Expect.equal staged.seed m.seed
                    ]
                    ()
        , test "iqResume on IqDingScheduled with no preserved dingDelay falls back to drawing a fresh one" <|
            \_ ->
                let
                    staged =
                        { baseModel
                            | connectedPlayers = Dict.singleton "uuid1" "c1"
                            , iqTimers = Dict.singleton "uuid1" { iqState | phase = IqDingScheduled, dingDelay = Nothing }
                        }

                    ( m, _ ) =
                        update (iqTimerMsg "c1" "iqResume") staged
                in
                Expect.notEqual staged.seed m.seed
        ]


-- ── Admin state-edit reconciliation with the server's IQ timer ──────────────
-- The server's iqTimers is now the sole authority on the IQ countdown/count,
-- separate from the persisted registry JSON edit:state edits. Without
-- reconcileIqTimerAfterEdit, an edited countdown/count is silently clobbered
-- the moment the server resends its own (unrelated) value on the next
-- iqResume -- this is exactly the bug report: "start countdown at 100s, edit
-- state to 5s, click begin, still 100s".


editedScreenState : String -> List ( String, Encode.Value ) -> Encode.Value
editedScreenState tag fields =
    Encode.object
        [ ( "screen"
          , Encode.object [ ( "tag", Encode.string tag ), ( "state", Encode.object fields ) ]
          )
        ]


iqEditSuite : Test
iqEditSuite =
    describe "reconcileIqTimerAfterEdit"
        [ describe "decodeEditedIqScreen"
            [ test "decodes an edited IQTestCountdownScreen's countdown/totalDings" <|
                \_ ->
                    editedScreenState "IQTestCountdownScreen" [ ( "questionIdx", Encode.int 0 ), ( "countdown", Encode.int 5 ), ( "totalDings", Encode.int 100 ) ]
                        |> Decode.decodeValue decodeEditedIqScreen
                        |> Expect.equal (Ok (EditedIqCountdown { countdown = 5, totalDings = 100 }))
            , test "decodes an edited IQTestActiveScreen's dingCount/totalDings" <|
                \_ ->
                    editedScreenState "IQTestActiveScreen"
                        [ ( "questionIdx", Encode.int 0 ), ( "dingCount", Encode.int 3 ), ( "totalDings", Encode.int 100 )
                        , ( "isFlashing", Encode.bool False ), ( "dingActive", Encode.bool False )
                        , ( "fakeFlashActive", Encode.bool False ), ( "fakeIsTrap", Encode.bool False ), ( "loudPlaying", Encode.bool False )
                        ]
                        |> Decode.decodeValue decodeEditedIqScreen
                        |> Expect.equal (Ok (EditedIqActive { dingCount = 3, totalDings = 100 }))
            , test "decodes an edited IQTestScreen's totalDings" <|
                \_ ->
                    editedScreenState "IQTestScreen" [ ( "questionIdx", Encode.int 0 ), ( "totalDings", Encode.int 200 ) ]
                        |> Decode.decodeValue decodeEditedIqScreen
                        |> Expect.equal (Ok (EditedIqBegin { totalDings = 200 }))
            , test "a non-IQ screen decodes to EditedIqOther" <|
                \_ ->
                    Encode.object [ ( "screen", Encode.object [ ( "tag", Encode.string "QuestionScreen" ) ] ) ]
                        |> Decode.decodeValue decodeEditedIqScreen
                        |> Expect.equal (Ok EditedIqOther)
            , test "malformed JSON (no screen field) decodes to EditedIqOther rather than failing" <|
                \_ ->
                    Encode.object []
                        |> Decode.decodeValue decodeEditedIqScreen
                        |> Expect.equal (Ok EditedIqOther)
            ]
        , test "reconciles a paused countdown to the edited value (the reported bug)" <|
            \_ ->
                let
                    -- Countdown was started at iqQuestionCount and paused (disconnected) partway.
                    paused =
                        { baseModel | iqTimers = Dict.singleton "uuid1" { iqState | phase = IqCounting, countdownRemaining = 63, totalDings = IQTest.iqQuestionCount } }

                    edited =
                        editedScreenState "IQTestCountdownScreen" [ ( "questionIdx", Encode.int 0 ), ( "countdown", Encode.int 5 ), ( "totalDings", Encode.int IQTest.iqQuestionCount ) ]

                    reconciled =
                        reconcileIqTimerAfterEdit "uuid1" edited paused
                in
                Dict.get "uuid1" reconciled.iqTimers
                    |> Maybe.map (\s -> ( s.countdownRemaining, s.phase ))
                    |> Expect.equal (Just ( 5, IqCounting ))
        , test "reconciling an IQTestActiveScreen edit sets dingCount/totalDings and awaits the next ding" <|
            \_ ->
                let
                    edited =
                        editedScreenState "IQTestActiveScreen"
                            [ ( "questionIdx", Encode.int 0 ), ( "dingCount", Encode.int 40 ), ( "totalDings", Encode.int 100 )
                            , ( "isFlashing", Encode.bool False ), ( "dingActive", Encode.bool False )
                            , ( "fakeFlashActive", Encode.bool False ), ( "fakeIsTrap", Encode.bool False ), ( "loudPlaying", Encode.bool False )
                            ]

                    reconciled =
                        reconcileIqTimerAfterEdit "uuid1" edited baseModel
                in
                Dict.get "uuid1" reconciled.iqTimers
                    |> Maybe.map (\s -> ( s.dingCount, s.totalDings, s.phase ))
                    |> Expect.equal (Just ( 40, 100, IqAwaitingReady ))
        , test "reconciling an edit to a non-IQ screen leaves any existing timer untouched" <|
            \_ ->
                let
                    staged =
                        { baseModel | iqTimers = Dict.singleton "uuid1" { iqState | dingCount = 7 } }

                    edited =
                        Encode.object [ ( "screen", Encode.object [ ( "tag", Encode.string "QuestionScreen" ) ] ) ]

                    reconciled =
                        reconcileIqTimerAfterEdit "uuid1" edited staged
                in
                Dict.get "uuid1" reconciled.iqTimers
                    |> Maybe.map .dingCount
                    |> Expect.equal (Just 7)
        , test "reconciling a countdown edit also persists the re-derived screen/iqTimer into the registry (not just iqTimers)" <|
            \_ ->
                let
                    -- Mirrors the real call site: the admin's raw edit is applied to the
                    -- registry *before* reconcileIqTimerAfterEdit runs (see the ordering fix
                    -- in ClientDistStateEditSave).
                    rawEdited =
                        editedScreenState "IQTestCountdownScreen" [ ( "questionIdx", Encode.int 0 ), ( "countdown", Encode.int 5 ), ( "totalDings", Encode.int IQTest.iqQuestionCount ) ]

                    editedRegistry =
                        List.map
                            (\e ->
                                if e.uuid == "uuid1" then
                                    { e | state = Just rawEdited }

                                else
                                    e
                            )
                            baseModel.registry

                    reconciled =
                        reconcileIqTimerAfterEdit "uuid1" rawEdited { baseModel | registry = editedRegistry }

                    entryOf uuid =
                        reconciled.registry |> List.filter (\e -> e.uuid == uuid) |> List.head
                in
                Expect.all
                    [ \_ -> entryOf "uuid1" |> Maybe.andThen .iqTimer |> Expect.notEqual Nothing
                    , \_ ->
                        entryOf "uuid1"
                            |> Maybe.andThen .state
                            |> Maybe.andThen (Decode.decodeValue (Decode.at [ "screen", "state", "countdown" ] Decode.int) >> Result.toMaybe)
                            |> Expect.equal (Just 5)
                    ]
                    ()
        ]


-- ── Persistence: server state mirrored into builds.jsonl (IQ-only stepping stone) ──


iqTimerCodecSuite : Test
iqTimerCodecSuite =
    describe "encodeIqTimerStateFull / decodeIqTimerStateFull"
        [ test "round-trips every field, including the two never shown to the client" <|
            \_ ->
                let
                    state =
                        { iqState
                            | epoch = 9
                            , phase = IqDingScheduled
                            , questionIdx = 2
                            , countdownRemaining = 3
                            , dingCount = 7
                            , totalDings = 150
                            , fakeFlashPoint = 42
                            , fakeFlashUsed = True
                            , in50PercentPhase = True
                            , lastDing = PhaseFake
                            , dingDelay = Just 8500
                        }
                in
                state
                    |> encodeIqTimerStateFull
                    |> Decode.decodeValue decodeIqTimerStateFull
                    |> Expect.equal (Ok state)
        , test "round-trips a Nothing dingDelay" <|
            \_ ->
                let
                    state =
                        { iqState | phase = IqAwaitingReady, dingDelay = Nothing }
                in
                state
                    |> encodeIqTimerStateFull
                    |> Decode.decodeValue decodeIqTimerStateFull
                    |> Expect.equal (Ok state)
        , test "decodes a JSON blob missing dingDelay entirely as Nothing (back-compat with pre-fix persisted entries)" <|
            \_ ->
                let
                    legacyJson =
                        Encode.object
                            [ ( "epoch", Encode.int 1 )
                            , ( "phase", Encode.string "IqDingScheduled" )
                            , ( "questionIdx", Encode.int 0 )
                            , ( "countdownRemaining", Encode.int 0 )
                            , ( "dingCount", Encode.int 10 )
                            , ( "totalDings", Encode.int IQTest.iqQuestionCount )
                            , ( "fakeFlashPoint", Encode.int 90 )
                            , ( "fakeFlashUsed", Encode.bool False )
                            , ( "in50PercentPhase", Encode.bool False )
                            , ( "lastDing", Encode.string "RealDing" )
                            ]
                in
                legacyJson
                    |> Decode.decodeValue decodeIqTimerStateFull
                    |> Result.toMaybe
                    |> Maybe.andThen .dingDelay
                    |> Expect.equal Nothing
        ]


deriveIqScreenSuite : Test
deriveIqScreenSuite =
    describe "deriveIqScreen"
        [ test "IqCounting derives an IQTestCountdownScreen decodable by Sync's real decoder" <|
            \_ ->
                { iqState | phase = IqCounting, countdownRemaining = 42, totalDings = 100, questionIdx = 3 }
                    |> deriveIqScreen
                    |> Maybe.andThen (Decode.decodeValue (Decode.field "state" decodeIQTestCountdownState) >> Result.toMaybe)
                    |> Expect.equal (Just { questionIdx = 3, totalDings = 100, countdown = 42 })
        , test "IqAwaitingReady derives an inactive IQTestActiveScreen" <|
            \_ ->
                { iqState | phase = IqAwaitingReady, dingCount = 3, totalDings = 100, questionIdx = 2 }
                    |> deriveIqScreen
                    |> Maybe.andThen (Decode.decodeValue (Decode.field "state" decodeIQTestState) >> Result.toMaybe)
                    |> Expect.equal
                        (Just
                            { questionIdx = 2
                            , dingCount = 3
                            , totalDings = 100
                            , isFlashing = False
                            , dingActive = False
                            , fakeFlashActive = False
                            , fakeIsTrap = False
                            , loudPlaying = False
                            }
                        )
        , test "IqDingScheduled also derives an inactive IQTestActiveScreen" <|
            \_ ->
                { iqState | phase = IqDingScheduled, dingCount = 3, totalDings = 100 }
                    |> deriveIqScreen
                    |> Maybe.andThen (Decode.decodeValue (Decode.field "state" decodeIQTestState) >> Result.toMaybe)
                    |> Maybe.map .isFlashing
                    |> Expect.equal (Just False)
        , test "IqDingShown with a real ding derives an active flash; loudPlaying kicks in at dingCount 4" <|
            \_ ->
                { iqState | phase = IqDingShown, lastDing = RealDing, dingCount = 4, totalDings = 100 }
                    |> deriveIqScreen
                    |> Maybe.andThen (Decode.decodeValue (Decode.field "state" decodeIQTestState) >> Result.toMaybe)
                    |> Expect.equal
                        (Just
                            { questionIdx = 0
                            , dingCount = 4
                            , totalDings = 100
                            , isFlashing = True
                            , dingActive = True
                            , fakeFlashActive = False
                            , fakeIsTrap = False
                            , loudPlaying = True
                            }
                        )
        , test "IqDingShown with a trap fake derives a fake flash with fakeIsTrap" <|
            \_ ->
                { iqState | phase = IqDingShown, lastDing = TrapFake, dingCount = 1 }
                    |> deriveIqScreen
                    |> Maybe.andThen (Decode.decodeValue (Decode.field "state" decodeIQTestState) >> Result.toMaybe)
                    |> Maybe.map (\s -> ( s.dingActive, s.fakeFlashActive, s.fakeIsTrap ))
                    |> Expect.equal (Just ( False, True, True ))
        , test "IqDingShown with a phase fake derives a fake flash without fakeIsTrap" <|
            \_ ->
                { iqState | phase = IqDingShown, lastDing = PhaseFake, dingCount = 1 }
                    |> deriveIqScreen
                    |> Maybe.andThen (Decode.decodeValue (Decode.field "state" decodeIQTestState) >> Result.toMaybe)
                    |> Maybe.map (\s -> ( s.fakeFlashActive, s.fakeIsTrap ))
                    |> Expect.equal (Just ( True, False ))
        , test "IqIdle is not derivable -- the client's own report (cutscene or not-yet-started) stays authoritative" <|
            \_ -> deriveIqScreen { iqState | phase = IqIdle } |> Expect.equal Nothing
        ]


extractQuestionIdxSuite : Test
extractQuestionIdxSuite =
    describe "extractQuestionIdx"
        [ test "reads questionIdx from the IQTestScreen-family shape (screen.state.questionIdx)" <|
            \_ ->
                Encode.object
                    [ ( "screen"
                      , Encode.object
                            [ ( "tag", Encode.string "IQTestCountdownScreen" )
                            , ( "state", Encode.object [ ( "questionIdx", Encode.int 4 ) ] )
                            ]
                      )
                    ]
                    |> extractQuestionIdx
                    |> Expect.equal 4
        , test "reads idx from the top-level screen.idx shape (WrongAnswerScreen/BlankScreen/etc.)" <|
            \_ ->
                Encode.object
                    [ ( "screen", Encode.object [ ( "tag", Encode.string "QuestionScreen" ), ( "idx", Encode.int 7 ) ] ) ]
                    |> extractQuestionIdx
                    |> Expect.equal 7
        , test "defaults to 0 when neither shape is present" <|
            \_ -> extractQuestionIdx (Encode.object []) |> Expect.equal 0
        ]


persistIqTimerInRegistrySuite : Test
persistIqTimerInRegistrySuite =
    describe "persistIqTimerInRegistry"
        [ test "sets a decodable iqTimer and overwrites only the screen key, preserving the rest of state" <|
            \_ ->
                let
                    existing =
                        [ { uuid = "uuid1"
                          , filename = "f.dmg"
                          , platform = "mac"
                          , state =
                                Just
                                    (Encode.object
                                        [ ( "screen", Encode.object [ ( "tag", Encode.string "IQTestScreen" ) ] )
                                        , ( "pending", Encode.list identity [] )
                                        , ( "now", Encode.float 42 )
                                        ]
                                    )
                          , pendingStateEdit = False
                          , winText = ""
                          , iqTimer = Nothing
                          }
                        ]

                    state =
                        { iqState | phase = IqCounting, countdownRemaining = 7, totalDings = 100, questionIdx = 0 }

                    updated =
                        persistIqTimerInRegistry "uuid1" (Just state) existing |> List.head

                    decodedIqTimer =
                        updated |> Maybe.andThen .iqTimer |> Maybe.andThen (Decode.decodeValue decodeIqTimerStateFull >> Result.toMaybe)

                    screenTagOf =
                        updated |> Maybe.andThen .state |> Maybe.andThen (Decode.decodeValue (Decode.at [ "screen", "tag" ] Decode.string) >> Result.toMaybe)

                    nowOf =
                        updated |> Maybe.andThen .state |> Maybe.andThen (Decode.decodeValue (Decode.field "now" Decode.float) >> Result.toMaybe)
                in
                Expect.all
                    [ \_ -> Expect.equal (Just state) decodedIqTimer
                    , \_ -> Expect.equal (Just "IQTestCountdownScreen") screenTagOf
                    , \_ -> Expect.equal (Just 42) nowOf
                    ]
                    ()
        , test "Nothing clears iqTimer and leaves state untouched entirely" <|
            \_ ->
                let
                    existing =
                        [ { uuid = "uuid1"
                          , filename = "f.dmg"
                          , platform = "mac"
                          , state = Just (Encode.object [ ( "screen", Encode.object [ ( "tag", Encode.string "BlankScreen" ) ] ) ])
                          , pendingStateEdit = False
                          , winText = ""
                          , iqTimer = Just (Encode.object [ ( "epoch", Encode.int 1 ) ])
                          }
                        ]

                    updated =
                        persistIqTimerInRegistry "uuid1" Nothing existing |> List.head

                    screenTagOf =
                        updated |> Maybe.andThen .state |> Maybe.andThen (Decode.decodeValue (Decode.at [ "screen", "tag" ] Decode.string) >> Result.toMaybe)
                in
                Expect.all
                    [ \_ -> Expect.equal Nothing (updated |> Maybe.andThen .iqTimer)
                    , \_ -> Expect.equal (Just "BlankScreen") screenTagOf
                    ]
                    ()
        , test "IqIdle (nothing derivable) still sets iqTimer but leaves state's screen untouched" <|
            \_ ->
                let
                    existing =
                        [ { uuid = "uuid1"
                          , filename = "f.dmg"
                          , platform = "mac"
                          , state = Just (Encode.object [ ( "screen", Encode.object [ ( "tag", Encode.string "FakeFlashCaughtScreen" ) ] ) ])
                          , pendingStateEdit = False
                          , winText = ""
                          , iqTimer = Nothing
                          }
                        ]

                    updated =
                        persistIqTimerInRegistry "uuid1" (Just { iqState | phase = IqIdle }) existing |> List.head

                    screenTagOf =
                        updated |> Maybe.andThen .state |> Maybe.andThen (Decode.decodeValue (Decode.at [ "screen", "tag" ] Decode.string) >> Result.toMaybe)
                in
                Expect.all
                    [ \_ -> updated |> Maybe.andThen .iqTimer |> Expect.notEqual Nothing
                    , \_ -> Expect.equal (Just "FakeFlashCaughtScreen") screenTagOf
                    ]
                    ()
        ]


iqPersistenceRoutingSuite : Test
iqPersistenceRoutingSuite =
    describe "IQ persistence wired into Server.update"
        [ test "iqStartCountdown persists the derived countdown screen and an iqTimer snapshot into the registry" <|
            \_ ->
                let
                    connected =
                        { baseModel | connectedPlayers = Dict.singleton "uuid1" "c1" }

                    ( m, _ ) =
                        update (iqTimerMsg "c1" "iqStartCountdown") connected

                    entryOf =
                        m.registry |> List.filter (\e -> e.uuid == "uuid1") |> List.head
                in
                Expect.all
                    [ \_ -> entryOf |> Maybe.andThen .iqTimer |> Expect.notEqual Nothing
                    , \_ ->
                        entryOf
                            |> Maybe.andThen .state
                            |> Maybe.andThen (Decode.decodeValue (Decode.at [ "screen", "tag" ] Decode.string) >> Result.toMaybe)
                            |> Expect.equal (Just "IQTestCountdownScreen")
                    ]
                    ()
        , test "a client stateUpdate for an IQ player can't clobber the server-derived screen" <|
            \_ ->
                let
                    staged =
                        { baseModel
                            | connectedPlayers = Dict.singleton "uuid1" "c1"
                            , iqTimers = Dict.singleton "uuid1" { iqState | phase = IqCounting, countdownRemaining = 5, totalDings = 100 }
                        }

                    -- The client self-reports a bogus/stale countdown (as if it never
                    -- received the server's ticks) -- this must not win.
                    bogusReport =
                        Encode.encode 0 (editedScreenState "IQTestCountdownScreen" [ ( "questionIdx", Encode.int 0 ), ( "countdown", Encode.int 9999 ), ( "totalDings", Encode.int 100 ) ])

                    ( m, _ ) =
                        update (MessageReceived { clientId = "c1", payload = clientEnvelope "stateUpdate" [ ( "json", Encode.string bogusReport ) ] }) staged

                    entryOf =
                        m.registry |> List.filter (\e -> e.uuid == "uuid1") |> List.head
                in
                entryOf
                    |> Maybe.andThen .state
                    |> Maybe.andThen (Decode.decodeValue (Decode.at [ "screen", "state", "countdown" ] Decode.int) >> Result.toMaybe)
                    |> Expect.equal (Just 5)
        , test "test completion clears a previously-set registry iqTimer (via clearIqTimer)" <|
            \_ ->
                let
                    ( withTimer, _ ) =
                        setIqTimer "uuid1" { iqState | phase = IqDingShown } baseModel

                    ( cleared, _ ) =
                        clearIqTimer "uuid1" withTimer

                    entryOf =
                        cleared.registry |> List.filter (\e -> e.uuid == "uuid1") |> List.head
                in
                Expect.all
                    [ \_ -> Dict.get "uuid1" cleared.iqTimers |> Expect.equal Nothing
                    , \_ -> entryOf |> Maybe.andThen .iqTimer |> Expect.equal Nothing
                    ]
                    ()
        , test "setIqTimer keeps iqTimers and the registry in agreement" <|
            \_ ->
                let
                    ( m, _ ) =
                        setIqTimer "uuid1" { iqState | phase = IqCounting, countdownRemaining = 11 } baseModel

                    entryOf =
                        m.registry |> List.filter (\e -> e.uuid == "uuid1") |> List.head
                in
                Expect.all
                    [ \_ -> Dict.get "uuid1" m.iqTimers |> Maybe.map .countdownRemaining |> Expect.equal (Just 11)
                    , \_ ->
                        entryOf
                            |> Maybe.andThen .state
                            |> Maybe.andThen (Decode.decodeValue (Decode.at [ "screen", "state", "countdown" ] Decode.int) >> Result.toMaybe)
                            |> Expect.equal (Just 11)
                    ]
                    ()
        ]
