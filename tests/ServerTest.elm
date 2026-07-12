module ServerTest exposing (..)

import Dict
import Expect
import Game.IQTest as IQTest
import Game.Quiz exposing (Question)
import Json.Decode as Decode
import Json.Encode as Encode
import Random
import Time
import Server
    exposing
        ( ClearOutcome(..)
        , DingKind(..)
        , IqPhase(..)
        , IqTimerState
        , Model
        , Msg(..)
        , acceptQuizAdvance
        , advanceOnClear
        , applyCatch
        , classifyDing
        , classifyFileRead
        , clearIqTimer
        , decodeDingKind
        , decodeIqPhase
        , decodeIqTimerStateFull
        , deriveIqScreen
        , deriveQuizScreen
        , deriveQuizOrWinScreen
        , deriveTimedOutScreen
        , deriveWinScreen
        , encodeIqTimerStateFull
        , persistIqTimerInRegistry
        , persistQuizScreenInRegistry
        , questionsForUuid
        , quizJustCompleted
        , resumeIqTimer
        , sendToClient
        , setIqTimer
        , update
        , writeRegistry
        )
import Server.Distribution exposing (DistStage(..))
import Server.Protocol
    exposing
        ( ClientEnvelope(..)
        , decodeClientEnvelope
        , distListResultEnvelope
        , iqDingEnvelope
        , distRegisterAckEnvelope
        , quizAnswerResultEnvelope
        , stateEnvelope
        , stateUpdateAckEnvelope
        , timedOutEnvelope
        , timerSyncEnvelope
        , winTextEnvelope
        )
import Server.Registry
    exposing
        ( RegistryEntry
        , decodeRegistry
        , decodeRegistryEntry
        , decodeServerStateFields
        , encodeRegistry
        , encodeRegistryEntry
        , encodeServerStateFields
        , findUuidByClient
        , isExpired
        , registryFilePath
        , updateEntryTimer
        )
import Sync exposing (decodeFakeFlashCaughtState, decodeIQTestCountdownState, decodeIQTestScreenState, decodeIQTestState, decodeScreen)
import Set
import String
import Test exposing (Test, describe, test)
import Types exposing (Screen(..))


winTextOf : Encode.Value -> Maybe String
winTextOf value =
    Decode.decodeValue (Decode.at [ "winText", "text" ] Decode.string) value
        |> Result.toMaybe


registrySuite : Test
registrySuite =
    describe "RegistryEntry winText codec"
        [ test "round-trips winText through encode/decode" <|
            \_ ->
                { uuid = "u1", filename = "f.dmg", platform = "mac", pendingStateEdit = False, winText = "claim your reward", iqTimer = Nothing, quizProgress = 0, timerEndsAt = Nothing, quizQuestions = Nothing }
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
        , test "ignores a stale state key left over from an older row" <|
            \_ ->
                """{"uuid":"u","filename":"f","platform":"mac","state":{"tag":"BeginScreen","nextScreen":{"tag":"BlankScreen","idx":0}},"pendingStateEdit":false}"""
                    |> Decode.decodeString decodeRegistryEntry
                    |> Result.map .uuid
                    |> Expect.equal (Ok "u")
        ]


quizQuestionsRegistrySuite : Test
quizQuestionsRegistrySuite =
    describe "RegistryEntry.quizQuestions codec"
        [ test "round-trips quizQuestions through encode/decode" <|
            \_ ->
                entry "u1"
                    |> encodeRegistryEntry
                    |> Encode.encode 0
                    |> Decode.decodeString decodeRegistryEntry
                    |> Result.map .quizQuestions
                    |> Expect.equal (Ok (Just (encodeTestQuestions baseQuizQuestions)))
        , test "defaults quizQuestions to Nothing for older rows missing the field" <|
            \_ ->
                """{"uuid":"u","filename":"f","platform":"mac","state":null,"pendingStateEdit":false}"""
                    |> Decode.decodeString decodeRegistryEntry
                    |> Result.map .quizQuestions
                    |> Expect.equal (Ok Nothing)
        , test "defaults quizQuestions to Nothing when explicitly serialized as null" <|
            \_ ->
                """{"uuid":"u","filename":"f","platform":"mac","state":null,"pendingStateEdit":false,"quizQuestions":null}"""
                    |> Decode.decodeString decodeRegistryEntry
                    |> Result.map .quizQuestions
                    |> Expect.equal (Ok Nothing)
        ]


questionsForUuidSuite : Test
questionsForUuidSuite =
    describe "questionsForUuid"
        [ test "resolves the connecting player's own build's questions from the registry" <|
            \_ ->
                questionsForUuid "uuid1" baseModel.registry
                    |> Expect.equal baseQuizQuestions
        , test "a different uuid on a different build resolves independently" <|
            \_ ->
                let
                    entryUuid1 =
                        entry "uuid1"

                    registry =
                        [ { entryUuid1 | quizQuestions = Just (encodeTestQuestions [ Question [ "only" ] ]) }
                        , entry "uuid2"
                        ]
                in
                Expect.all
                    [ \_ -> questionsForUuid "uuid1" registry |> Expect.equal [ Question [ "only" ] ]
                    , \_ -> questionsForUuid "uuid2" registry |> Expect.equal baseQuizQuestions
                    ]
                    ()
        , test "an unknown uuid resolves to []" <|
            \_ ->
                questionsForUuid "no-such-uuid" baseModel.registry
                    |> Expect.equal []
        , test "a registry entry with quizQuestions = Nothing resolves to []" <|
            \_ ->
                let
                    entryU =
                        entry "u"
                in
                questionsForUuid "u" [ { entryU | quizQuestions = Nothing } ]
                    |> Expect.equal []
        ]


encodeRegistryTests : Test
encodeRegistryTests =
    describe "encodeRegistry"
        [ test "an empty registry encodes to a well-formed empty builds document" <|
            \_ ->
                encodeRegistry []
                    |> Decode.decodeString (Decode.field "builds" (Decode.list Decode.value))
                    |> Expect.equal (Ok [])
        , test "encodeRegistry output is newline-terminated" <|
            \_ ->
                encodeRegistry [ { uuid = "u1", filename = "f", platform = "mac", pendingStateEdit = False, winText = "", iqTimer = Nothing, quizProgress = 0, timerEndsAt = Nothing, quizQuestions = Nothing } ]
                    |> String.endsWith "\n"
                    |> Expect.equal True
        ]


decodeRegistryTests : Test
decodeRegistryTests =
    describe "decodeRegistry"
        [ test "parses a builds document, skipping a malformed entry" <|
            \_ ->
                let
                    raw =
                        """{"builds":[{"uuid":"u1","filename":"f1","platform":"mac","state":null,"pendingStateEdit":false},{"not":"an entry"},{"uuid":"u2","filename":"f2","platform":"win","state":null,"pendingStateEdit":false}]}"""
                in
                decodeRegistry raw
                    |> List.map .uuid
                    |> Expect.equal [ "u1", "u2" ]
        , test "totally garbled input decodes to an empty registry" <|
            \_ -> decodeRegistry "not json" |> Expect.equal []
        , test "a document missing the builds field decodes to an empty registry" <|
            \_ -> decodeRegistry """{"other":[]}""" |> Expect.equal []
        , test "round-trips a registry through encode then decode" <|
            \_ ->
                let
                    entries =
                        [ { uuid = "u1", filename = "f1", platform = "mac", pendingStateEdit = False, winText = "", iqTimer = Nothing, quizProgress = 0, timerEndsAt = Nothing, quizQuestions = Nothing }
                        , { uuid = "u2", filename = "f2", platform = "win", pendingStateEdit = True, winText = "you win", iqTimer = Nothing, quizProgress = 3, timerEndsAt = Just 42, quizQuestions = Nothing }
                        ]
                in
                entries
                    |> encodeRegistry
                    |> decodeRegistry
                    |> Expect.equal entries
        ]


findUuidByClientTests : Test
findUuidByClientTests =
    describe "findUuidByClient"
        [ test "finds the uuid mapped to a connected clientId" <|
            \_ ->
                findUuidByClient "c1" (Dict.fromList [ ( "uuid1", "c1" ), ( "uuid2", "c2" ) ])
                    |> Expect.equal (Just "uuid1")
        , test "Nothing when no uuid maps to that clientId" <|
            \_ ->
                findUuidByClient "unknown" (Dict.fromList [ ( "uuid1", "c1" ) ])
                    |> Expect.equal Nothing
        ]


timerSuite : Test
timerSuite =
    describe "RegistryEntry.timerEndsAt"
        [ test "round-trips a set deadline through encode/decode" <|
            \_ ->
                { uuid = "u1", filename = "f.dmg", platform = "mac", pendingStateEdit = False, winText = "", iqTimer = Nothing, quizProgress = 0, timerEndsAt = Just 12345, quizQuestions = Nothing }
                    |> encodeRegistryEntry
                    |> Encode.encode 0
                    |> Decode.decodeString decodeRegistryEntry
                    |> Result.map .timerEndsAt
                    |> Expect.equal (Ok (Just 12345))
        , test "defaults timerEndsAt to Nothing for older rows missing the field" <|
            \_ ->
                """{"uuid":"u","filename":"f","platform":"mac","state":null,"pendingStateEdit":false}"""
                    |> Decode.decodeString decodeRegistryEntry
                    |> Result.map .timerEndsAt
                    |> Expect.equal (Ok Nothing)
        , test "updateEntryTimer sets the deadline only on the matching uuid" <|
            \_ ->
                [ entry "uuid1", entry "uuid2" ]
                    |> updateEntryTimer "uuid1" 999
                    |> List.map (\e -> ( e.uuid, e.timerEndsAt ))
                    |> Expect.equal [ ( "uuid1", Just 999 ), ( "uuid2", Nothing ) ]
        , test "isExpired is False when no deadline has been established yet" <|
            \_ ->
                entry "uuid1"
                    |> isExpired 1000000
                    |> Expect.equal False
        , test "isExpired is False before the deadline" <|
            \_ ->
                { uuid = "u", filename = "f", platform = "mac", pendingStateEdit = False, winText = "", iqTimer = Nothing, quizProgress = 0, timerEndsAt = Just 2000, quizQuestions = Nothing }
                    |> isExpired 1000
                    |> Expect.equal False
        , test "isExpired is True once now reaches the deadline" <|
            \_ ->
                { uuid = "u", filename = "f", platform = "mac", pendingStateEdit = False, winText = "", iqTimer = Nothing, quizProgress = 0, timerEndsAt = Just 1000, quizQuestions = Nothing }
                    |> isExpired 1000
                    |> Expect.equal True
        , test "timerSyncEnvelope carries the deadline under timerSync.timerEndsAt" <|
            \_ ->
                timerSyncEnvelope 4242
                    |> Decode.decodeValue (Decode.at [ "timerSync", "timerEndsAt" ] Decode.float)
                    |> Expect.equal (Ok 4242)
        , test "timedOutEnvelope tags its payload as timedOut" <|
            \_ ->
                timedOutEnvelope
                    |> Decode.decodeValue (Decode.field "payload" Decode.string)
                    |> Expect.equal (Ok "timedOut")
        ]


protocolSuite : Test
protocolSuite =
    describe "win detection and delivery"
        [ test "winTextEnvelope carries the text under winText.text" <|
            \_ ->
                winTextEnvelope "hello reward"
                    |> winTextOf
                    |> Expect.equal (Just "hello reward")
        ]


stateEnvelopeTests : Test
stateEnvelopeTests =
    describe "stateEnvelope"
        [ test "wraps an encoded state under stateUpdate.json" <|
            \_ ->
                stateEnvelope (Encode.object [ ( "a", Encode.int 1 ) ])
                    |> Decode.decodeValue (Decode.at [ "stateUpdate", "json" ] Decode.string)
                    |> Expect.equal (Ok """{"a":1}""")
        ]


clientEnvelopeSuite : Test
clientEnvelopeSuite =
    describe "decodeClientEnvelope"
        [ test "stateUpdate with malformed inner JSON maps to ClientUnknown" <|
            \_ ->
                """{"payload":"stateUpdate","stateUpdate":{"json":"not json"}}"""
                    |> Decode.decodeString decodeClientEnvelope
                    |> Expect.equal (Ok ClientUnknown)
        , test "stateRequest carries the uuid" <|
            \_ ->
                """{"payload":"stateRequest","stateRequest":{"uuid":"u1"}}"""
                    |> Decode.decodeString decodeClientEnvelope
                    |> Expect.equal (Ok (ClientStateRequest "u1"))
        , test "distRegister carries uuid and platform" <|
            \_ ->
                """{"payload":"distRegister","distRegister":{"uuid":"u1","platform":"mac"}}"""
                    |> Decode.decodeString decodeClientEnvelope
                    |> Expect.equal (Ok (ClientDistRegister { uuid = "u1", platform = "mac" }))
        , test "distUpload carries the chunk fields" <|
            \_ ->
                """{"payload":"distUpload","distUpload":{"uuid":"u1","filename":"f.dmg","contents":"YWJj","chunkIndex":2,"isLast":true}}"""
                    |> Decode.decodeString decodeClientEnvelope
                    |> Expect.equal (Ok (ClientDistUpload { uuid = "u1", filename = "f.dmg", contentsBase64 = "YWJj", chunkIndex = 2, isLast = True }))
        , test "distComplete carries winText and quizQuestions" <|
            \_ ->
                """{"payload":"distComplete","distComplete":{"uuid":"u1","filename":"f.dmg","winText":"gg","quizQuestions":[{"answers":["a"]}]}}"""
                    |> Decode.decodeString decodeClientEnvelope
                    |> Expect.equal
                        (Ok
                            (ClientDistComplete
                                { uuid = "u1"
                                , filename = "f.dmg"
                                , winText = "gg"
                                , quizQuestions = encodeTestQuestions [ Question [ "a" ] ]
                                }
                            )
                        )
        , test "distComplete without winText/quizQuestions defaults to empty" <|
            \_ ->
                """{"payload":"distComplete","distComplete":{"uuid":"u1","filename":"f.dmg"}}"""
                    |> Decode.decodeString decodeClientEnvelope
                    |> Expect.equal
                        (Ok
                            (ClientDistComplete
                                { uuid = "u1", filename = "f.dmg", winText = "", quizQuestions = Encode.list identity [] }
                            )
                        )
        , test "distStateEdit carries the uuid" <|
            \_ ->
                """{"payload":"distStateEdit","distStateEdit":{"uuid":"u1"}}"""
                    |> Decode.decodeString decodeClientEnvelope
                    |> Expect.equal (Ok (ClientDistStateEdit "u1"))
        , test "distReplaceComplete carries the uuid swap, filename, quizQuestions and winText" <|
            \_ ->
                """{"payload":"distReplaceComplete","distReplaceComplete":{"newUuid":"n","oldUuid":"o","filename":"f.dmg","quizQuestions":[{"answers":["x"]}],"winText":"gg2"}}"""
                    |> Decode.decodeString decodeClientEnvelope
                    |> Expect.equal
                        (Ok
                            (ClientDistReplaceComplete
                                { newUuid = "n"
                                , oldUuid = "o"
                                , filename = "f.dmg"
                                , quizQuestions = encodeTestQuestions [ Question [ "x" ] ]
                                , winText = "gg2"
                                }
                            )
                        )
        , test "distReplaceComplete without quizQuestions/winText defaults to empty" <|
            \_ ->
                """{"payload":"distReplaceComplete","distReplaceComplete":{"newUuid":"n","oldUuid":"o","filename":"f.dmg"}}"""
                    |> Decode.decodeString decodeClientEnvelope
                    |> Expect.equal
                        (Ok
                            (ClientDistReplaceComplete
                                { newUuid = "n"
                                , oldUuid = "o"
                                , filename = "f.dmg"
                                , quizQuestions = Encode.list identity []
                                , winText = ""
                                }
                            )
                        )
        , test "an unrecognized payload maps to ClientUnknown" <|
            \_ ->
                """{"payload":"somethingElse"}"""
                    |> Decode.decodeString decodeClientEnvelope
                    |> Expect.equal (Ok ClientUnknown)
        ]


-- ── Admin-op routing (migrated from server/index.js) ────────────────────────


resultIsOk : Result e a -> Bool
resultIsOk r =
    case r of
        Ok _ ->
            True

        Err _ ->
            False


encodeTestQuestions : List Question -> Encode.Value
encodeTestQuestions questions =
    Encode.list (\q -> Encode.object [ ( "answers", Encode.list Encode.string q.answers ) ]) questions


baseQuizQuestions : List Question
baseQuizQuestions =
    [ Question [ "Alpha" ], Question [ "Beta" ], Question [ "Gamma" ] ]


entry : String -> RegistryEntry
entry uuid =
    { uuid = uuid
    , filename = uuid ++ ".dmg"
    , platform = "mac"
    , pendingStateEdit = False
    , winText = ""
    , iqTimer = Nothing
    , quizProgress = 0
    , timerEndsAt = Nothing
    , quizQuestions = Just (encodeTestQuestions baseQuizQuestions)
    }


baseModel : Model
baseModel =
    { connectedPlayers = Dict.empty
    , distClients = Dict.empty
    , registry = [ entry "uuid1", entry "uuid2" ]
    , pendingStateEdits = Set.empty
    , iqTimers = Dict.empty
    , seed = Random.initialSeed 0
    , quizProgress = Dict.empty
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
        , now = 0
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
        , now = 0
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
    MessageReceived { clientId = clientId, payload = clientEnvelope variant [], now = 0 }


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
                    |> Expect.equal (Just ( 200, IqIdleCaught ))
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
        , test "iqResume on a phase with nothing to resume (IqIdleCaught) is a no-op" <|
            \_ ->
                let
                    staged =
                        { baseModel
                            | connectedPlayers = Dict.singleton "uuid1" "c1"
                            , iqTimers = Dict.singleton "uuid1" { iqState | phase = IqIdleCaught, totalDings = 200 }
                        }

                    ( m, _ ) =
                        update (iqTimerMsg "c1" "iqResume") staged
                in
                Dict.get "uuid1" m.iqTimers
                    |> Expect.equal (Just { iqState | phase = IqIdleCaught, totalDings = 200 })
        , test "iqResume on a phase with nothing to resume (IqIdleNotStarted) is a no-op" <|
            \_ ->
                let
                    staged =
                        { baseModel
                            | connectedPlayers = Dict.singleton "uuid1" "c1"
                            , iqTimers = Dict.singleton "uuid1" { iqState | phase = IqIdleNotStarted, totalDings = 200 }
                        }

                    ( m, _ ) =
                        update (iqTimerMsg "c1" "iqResume") staged
                in
                Dict.get "uuid1" m.iqTimers
                    |> Expect.equal (Just { iqState | phase = IqIdleNotStarted, totalDings = 200 })
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


-- ── Admin edit:state now writes iqTimer/quizProgress directly (issue #74) ────
-- The admin's saved JSON is the whole merged server-state document (see
-- encodeServerStateFields/decodeServerStateFields) -- iqTimer and quizProgress
-- are edited as their own real fields rather than inferred from the screen's
-- shape, so there's no more separate reconciliation step: the save handler
-- writes them straight into both the registry and the live
-- model.iqTimers/model.quizProgress dicts (the actual authority while a
-- player is connected).


editedScreenState : String -> List ( String, Encode.Value ) -> Encode.Value
editedScreenState tag fields =
    Encode.object [ ( "tag", Encode.string tag ), ( "state", Encode.object fields ) ]


iqEditSuite : Test
iqEditSuite =
    describe "edit:state writes iqTimer directly"
        [ test "saving a full iqTimer snapshot lands in both model.iqTimers and the registry" <|
            \_ ->
                let
                    editing =
                        { baseModel | distClients = Dict.singleton "c1" (EditingState "uuid1") }

                    editedState =
                        encodeServerStateFields
                            { winText = ""
                            , iqTimer = Just (encodeIqTimerStateFull { iqState | phase = IqCounting, countdownRemaining = 5 })
                            , quizProgress = 0
                            , timerEndsAt = Nothing
                            , quizQuestions = Nothing
                            }

                    ( m, _ ) =
                        update (saveMsg "c1" "uuid1" (Encode.encode 0 editedState)) editing

                    entryOf =
                        m.registry |> List.filter (\e -> e.uuid == "uuid1") |> List.head
                in
                Expect.all
                    [ \_ -> Dict.get "uuid1" m.iqTimers |> Maybe.map (\s -> ( s.countdownRemaining, s.phase )) |> Expect.equal (Just ( 5, IqCounting ))
                    , \_ -> entryOf |> Maybe.andThen .iqTimer |> Expect.notEqual Nothing
                    ]
                    ()
        , test "saving with iqTimer: null clears both the live entry and the registry" <|
            \_ ->
                let
                    staged =
                        setIqTimer "uuid1" { iqState | phase = IqDingShown } baseModel |> Tuple.first

                    editing =
                        { staged | distClients = Dict.singleton "c1" (EditingState "uuid1") }

                    editedState =
                        encodeServerStateFields
                            { winText = "", iqTimer = Nothing, quizProgress = 0, timerEndsAt = Nothing, quizQuestions = Nothing }

                    ( m, _ ) =
                        update (saveMsg "c1" "uuid1" (Encode.encode 0 editedState)) editing

                    entryOf =
                        m.registry |> List.filter (\e -> e.uuid == "uuid1") |> List.head
                in
                Expect.all
                    [ \_ -> Dict.get "uuid1" m.iqTimers |> Expect.equal Nothing
                    , \_ -> entryOf |> Maybe.andThen .iqTimer |> Expect.equal Nothing
                    ]
                    ()
        ]


-- ── Persistence: server state mirrored into builds.json (IQ-only stepping stone) ──


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
        , test "IqIdleNotStarted derives an IQTestScreen" <|
            \_ ->
                { iqState | phase = IqIdleNotStarted, questionIdx = 2, totalDings = 100 }
                    |> deriveIqScreen
                    |> Maybe.andThen (Decode.decodeValue (Decode.field "state" decodeIQTestScreenState) >> Result.toMaybe)
                    |> Expect.equal (Just { questionIdx = 2, totalDings = 100 })
        , test "IqIdleCaught derives a FakeFlashCaughtScreen restarted at FfDelay" <|
            \_ ->
                { iqState | phase = IqIdleCaught, questionIdx = 2, totalDings = 200 }
                    |> deriveIqScreen
                    |> Maybe.andThen (Decode.decodeValue (Decode.field "state" decodeFakeFlashCaughtState) >> Result.toMaybe)
                    |> Expect.equal
                        (Just
                            { questionIdx = 2
                            , originalTotal = 100
                            , displayNumerator = 0
                            , displayDenominator = 100
                            , phase = IQTest.FfDelay
                            }
                        )
        ]


persistIqTimerInRegistrySuite : Test
persistIqTimerInRegistrySuite =
    describe "persistIqTimerInRegistry"
        [ test "sets a decodable iqTimer on the matching uuid" <|
            \_ ->
                let
                    existing =
                        [ { uuid = "uuid1"
                          , filename = "f.dmg"
                          , platform = "mac"
                          , pendingStateEdit = False
                          , winText = ""
                          , iqTimer = Nothing
                          , quizProgress = 0
                          , timerEndsAt = Nothing
                          , quizQuestions = Nothing
                          }
                        ]

                    state =
                        { iqState | phase = IqCounting, countdownRemaining = 7, totalDings = 100, questionIdx = 0 }

                    updated =
                        persistIqTimerInRegistry "uuid1" (Just state) existing |> List.head

                    decodedIqTimer =
                        updated |> Maybe.andThen .iqTimer |> Maybe.andThen (Decode.decodeValue decodeIqTimerStateFull >> Result.toMaybe)
                in
                Expect.equal (Just state) decodedIqTimer
        , test "Nothing clears iqTimer" <|
            \_ ->
                let
                    existing =
                        [ { uuid = "uuid1"
                          , filename = "f.dmg"
                          , platform = "mac"
                          , pendingStateEdit = False
                          , winText = ""
                          , iqTimer = Just (Encode.object [ ( "epoch", Encode.int 1 ) ])
                          , quizProgress = 0
                          , timerEndsAt = Nothing
                          , quizQuestions = Nothing
                          }
                        ]

                    updated =
                        persistIqTimerInRegistry "uuid1" Nothing existing |> List.head
                in
                Expect.equal Nothing (updated |> Maybe.andThen .iqTimer)
        ]


iqPersistenceRoutingSuite : Test
iqPersistenceRoutingSuite =
    describe "IQ persistence wired into Server.update"
        [ test "iqStartCountdown persists an iqTimer snapshot into the registry" <|
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
                            |> Maybe.andThen .iqTimer
                            |> Maybe.andThen (Decode.decodeValue decodeIqTimerStateFull >> Result.toMaybe)
                            |> Maybe.map .phase
                            |> Expect.equal (Just IqCounting)
                    ]
                    ()
        , test "a client stateUpdate no longer touches iqTimers or the registry at all -- the self-reported screen is never inspected" <|
            \_ ->
                let
                    staged =
                        { baseModel
                            | connectedPlayers = Dict.singleton "uuid1" "c1"
                            , iqTimers = Dict.singleton "uuid1" { iqState | phase = IqCounting, countdownRemaining = 5, totalDings = 100 }
                        }

                    -- The client self-reports a bogus/stale countdown (as if it never
                    -- received the server's ticks) -- irrelevant now, since
                    -- ClientStateUpdate no longer reads this payload at all.
                    bogusReport =
                        Encode.encode 0 (editedScreenState "IQTestCountdownScreen" [ ( "questionIdx", Encode.int 0 ), ( "countdown", Encode.int 9999 ), ( "totalDings", Encode.int 100 ) ])

                    ( m, _ ) =
                        update (MessageReceived { clientId = "c1", payload = clientEnvelope "stateUpdate" [ ( "json", Encode.string bogusReport ) ], now = 0 }) staged
                in
                Dict.get "uuid1" m.iqTimers
                    |> Maybe.map .countdownRemaining
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
                            |> Maybe.andThen .iqTimer
                            |> Maybe.andThen (Decode.decodeValue decodeIqTimerStateFull >> Result.toMaybe)
                            |> Maybe.map .countdownRemaining
                            |> Expect.equal (Just 11)
                    ]
                    ()
        ]


-- ── Remaining Server.update routing: connect/disconnect trivia, state
-- request/update, distribution upload/complete/replace, file I/O, and the
-- full IQ ready-for-ding / resume / countdown / ding-ready scheduling flow.


trivialMsgSuite : Test
trivialMsgSuite =
    describe "trivial Msg branches"
        [ test "ClientConnected is a no-op" <|
            \_ ->
                let
                    ( m, _ ) =
                        update (ClientConnected "c1") baseModel
                in
                m |> Expect.equal baseModel
        , test "ClientDisconnected for an unknown clientId is a no-op" <|
            \_ ->
                let
                    ( m, _ ) =
                        update (ClientDisconnected "unknown-client") baseModel
                in
                m |> Expect.equal baseModel
        , test "WriteFileCompleted is a no-op" <|
            \_ ->
                let
                    ( m, _ ) =
                        update (WriteFileCompleted { path = "x", ok = True, error = Nothing }) baseModel
                in
                m |> Expect.equal baseModel
        , test "GotTime reseeds the RNG" <|
            \_ ->
                let
                    ( m, _ ) =
                        update (GotTime (Time.millisToPosix 12345)) baseModel
                in
                m.seed |> Expect.notEqual baseModel.seed
        , test "AuthCompleted for a distClients stage it doesn't own is a no-op" <|
            \_ ->
                let
                    staged =
                        { baseModel | distClients = Dict.singleton "c1" (AwaitingUpload { uuid = "u1", platform = "mac" }) }

                    ( m, _ ) =
                        update (authDone "c1" True 2) staged
                in
                m.distClients |> Expect.equal staged.distClients
        , test "AuthCompleted for a clientId with no staged distClients entry is a no-op" <|
            \_ ->
                let
                    ( m, _ ) =
                        update (authDone "unstaged" True 2) baseModel
                in
                m |> Expect.equal baseModel
        ]


stateRequestMsg : String -> String -> Msg
stateRequestMsg clientId uuid =
    MessageReceived { clientId = clientId, payload = clientEnvelope "stateRequest" [ ( "uuid", Encode.string uuid ) ], now = 0 }


stateRequestSuite : Test
stateRequestSuite =
    describe "ClientStateRequest routing"
        [ test "rejects a uuid currently locked for admin state editing" <|
            \_ ->
                let
                    staged =
                        { baseModel | pendingStateEdits = Set.singleton "uuid1" }

                    ( m, _ ) =
                        update (stateRequestMsg "c1" "uuid1") staged
                in
                m.connectedPlayers |> Expect.equal Dict.empty
        , test "rejects a duplicate connection for an already-connected uuid" <|
            \_ ->
                let
                    staged =
                        { baseModel | connectedPlayers = Dict.singleton "uuid1" "existing-client" }

                    ( m, _ ) =
                        update (stateRequestMsg "c1" "uuid1") staged
                in
                m.connectedPlayers |> Expect.equal staged.connectedPlayers
        , test "rejects an unknown uuid not present in the registry" <|
            \_ ->
                let
                    ( m, _ ) =
                        update (stateRequestMsg "c1" "no-such-uuid") baseModel
                in
                m.connectedPlayers |> Expect.equal Dict.empty
        , test "establishes the deadline on this player's first connect and reuses it on file" <|
            \_ ->
                let
                    fresh =
                        { uuid = "uuid1", filename = "f.dmg", platform = "mac", pendingStateEdit = False, winText = "", iqTimer = Nothing, quizProgress = 0, timerEndsAt = Nothing, quizQuestions = Nothing }

                    staged =
                        { baseModel | registry = [ fresh ] }

                    ( m, _ ) =
                        update (stateRequestMsg "c1" "uuid1") staged
                in
                Expect.all
                    [ \mm -> Dict.get "uuid1" mm.connectedPlayers |> Expect.equal (Just "c1")
                    , \mm -> mm.registry |> List.head |> Maybe.andThen .timerEndsAt |> Expect.notEqual Nothing
                    ]
                    m
        , test "a truly fresh player (no iqTimer, no quiz progress, no quiz config) is delivered BeginScreen wrapping the safe BlankScreen 0 fallback" <|
            \_ ->
                let
                    fresh =
                        { uuid = "uuid1", filename = "f.dmg", platform = "mac", pendingStateEdit = False, winText = "", iqTimer = Nothing, quizProgress = 0, timerEndsAt = Just 999999, quizQuestions = Nothing }

                    staged =
                        { baseModel | registry = [ fresh ] }

                    ( m, cmd ) =
                        update (stateRequestMsg "c1" "uuid1") staged

                    expectedWrapped =
                        Encode.object
                            [ ( "tag", Encode.string "BeginScreen" )
                            , ( "nextScreen", Encode.object [ ( "tag", Encode.string "BlankScreen" ), ( "idx", Encode.int 0 ) ] )
                            ]
                in
                cmd
                    |> Expect.equal
                        (Cmd.batch
                            [ writeRegistry m.registry
                            , sendToClient { clientId = "c1", payload = stateEnvelope expectedWrapped }
                            , sendToClient { clientId = "c1", payload = timerSyncEnvelope 999999 }
                            ]
                        )
        , test "a player mid-quiz (no live iqTimer, quizProgress > 0) is delivered BeginScreen wrapping the earned BlankScreen slide" <|
            \_ ->
                let
                    base =
                        entry "uuid1"

                    staged =
                        { baseModel
                            | connectedPlayers = Dict.empty
                            , quizProgress = Dict.singleton "uuid1" 1
                            , registry = [ { base | timerEndsAt = Just 999999 } ]
                        }

                    ( m, cmd ) =
                        update (stateRequestMsg "c1" "uuid1") staged

                    expectedWrapped =
                        Encode.object
                            [ ( "tag", Encode.string "BeginScreen" )
                            , ( "nextScreen", Encode.object [ ( "tag", Encode.string "BlankScreen" ), ( "idx", Encode.int 1 ) ] )
                            ]
                in
                cmd
                    |> Expect.equal
                        (Cmd.batch
                            [ writeRegistry m.registry
                            , sendToClient { clientId = "c1", payload = stateEnvelope expectedWrapped }
                            , sendToClient { clientId = "c1", payload = timerSyncEnvelope 999999 }
                            ]
                        )
        , test "a player who has already earned every question (quizProgress >= total) is delivered BeginScreen wrapping WinScreen with the real winText, even without a live win-moment report" <|
            \_ ->
                let
                    base =
                        entry "uuid1"

                    staged =
                        { baseModel
                            | connectedPlayers = Dict.empty
                            , quizProgress = Dict.singleton "uuid1" (List.length baseQuizQuestions)
                            , registry = [ { base | timerEndsAt = Just 999999, winText = "you did it" } ]
                        }

                    ( m, cmd ) =
                        update (stateRequestMsg "c1" "uuid1") staged

                    expectedWrapped =
                        Encode.object
                            [ ( "tag", Encode.string "BeginScreen" )
                            , ( "nextScreen", Encode.object [ ( "tag", Encode.string "WinScreen" ), ( "text", Encode.string "you did it" ) ] )
                            ]
                in
                cmd
                    |> Expect.equal
                        (Cmd.batch
                            [ writeRegistry m.registry
                            , sendToClient { clientId = "c1", payload = stateEnvelope expectedWrapped }
                            , sendToClient { clientId = "c1", payload = timerSyncEnvelope 999999 }
                            ]
                        )
        , test "a player mid-IQ-test (live iqTimer) is delivered BeginScreen wrapping the derived IQ screen, taking priority over quiz progress" <|
            \_ ->
                let
                    base =
                        entry "uuid1"

                    staged =
                        { baseModel
                            | connectedPlayers = Dict.empty
                            , iqTimers = Dict.singleton "uuid1" { iqState | phase = IqIdleNotStarted, questionIdx = 1, totalDings = 100 }
                            , quizProgress = Dict.singleton "uuid1" 1
                            , registry = [ { base | timerEndsAt = Just 999999 } ]
                        }

                    ( m, cmd ) =
                        update (stateRequestMsg "c1" "uuid1") staged

                    expectedInner =
                        deriveIqScreen { iqState | phase = IqIdleNotStarted, questionIdx = 1, totalDings = 100 }
                            |> Maybe.withDefault (Encode.object [])

                    expectedWrapped =
                        Encode.object [ ( "tag", Encode.string "BeginScreen" ), ( "nextScreen", expectedInner ) ]
                in
                cmd
                    |> Expect.equal
                        (Cmd.batch
                            [ writeRegistry m.registry
                            , sendToClient { clientId = "c1", payload = stateEnvelope expectedWrapped }
                            , sendToClient { clientId = "c1", payload = timerSyncEnvelope 999999 }
                            ]
                        )
        , test "an already-expired session sends only timedOutEnvelope, never combined with a stateEnvelope in the same batch" <|
            \_ ->
                let
                    base =
                        entry "uuid1"

                    staged =
                        { baseModel
                            | connectedPlayers = Dict.empty
                            , registry = [ { base | timerEndsAt = Just 0 } ]
                        }

                    ( m, cmd ) =
                        update (stateRequestMsg "c1" "uuid1") staged
                in
                cmd
                    |> Expect.equal
                        (Cmd.batch
                            [ writeRegistry m.registry
                            , sendToClient { clientId = "c1", payload = timedOutEnvelope }
                            ]
                        )
        ]


stateUpdateMsg : String -> Encode.Value -> Msg
stateUpdateMsg clientId innerState =
    MessageReceived { clientId = clientId, payload = clientEnvelope "stateUpdate" [ ( "json", Encode.string (Encode.encode 0 innerState) ) ], now = 0 }


stateUpdateSuite : Test
stateUpdateSuite =
    describe "ClientStateUpdate routing"
        [ test "an update from an unconnected clientId is a no-op" <|
            \_ ->
                let
                    ( m, _ ) =
                        update (stateUpdateMsg "c1" (Encode.object [])) baseModel
                in
                m |> Expect.equal baseModel
        , test "a normal (non-expired) update never touches the registry or any in-memory dict, regardless of what the client self-reports, and replies with a plain ack" <|
            \_ ->
                let
                    -- Any old garbage -- a premature win claim, a stale IQ screen, whatever
                    -- -- since ClientStateUpdate no longer inspects this payload at all.
                    reported =
                        Encode.object [ ( "tag", Encode.string "WinScreen" ), ( "text", Encode.string "" ) ]

                    staged =
                        { baseModel | connectedPlayers = Dict.singleton "uuid1" "c1" }

                    ( m, cmd ) =
                        update (stateUpdateMsg "c1" reported) staged
                in
                Expect.all
                    [ \_ -> m |> Expect.equal staged
                    , \_ -> cmd |> Expect.equal (sendToClient { clientId = "c1", payload = stateUpdateAckEnvelope })
                    ]
                    ()
        , test "an expired session replies with only timedOutEnvelope, and still never touches the registry" <|
            \_ ->
                let
                    base =
                        entry "uuid1"

                    staged =
                        { baseModel
                            | connectedPlayers = Dict.singleton "uuid1" "c1"
                            , registry = [ { base | timerEndsAt = Just 0 } ]
                        }

                    ( m, cmd ) =
                        update (stateUpdateMsg "c1" (Encode.object [])) staged
                in
                Expect.all
                    [ \_ -> m |> Expect.equal staged
                    , \_ -> cmd |> Expect.equal (sendToClient { clientId = "c1", payload = timedOutEnvelope })
                    ]
                    ()
        ]


distUploadMsg : String -> String -> String -> Int -> Bool -> Msg
distUploadMsg clientId uuid filename chunkIndex isLast =
    MessageReceived
        { clientId = clientId
        , payload =
            clientEnvelope "distUpload"
                [ ( "uuid", Encode.string uuid )
                , ( "filename", Encode.string filename )
                , ( "contents", Encode.string "YWJj" )
                , ( "chunkIndex", Encode.int chunkIndex )
                , ( "isLast", Encode.bool isLast )
                ]
        , now = 0
        }


distUploadSuite : Test
distUploadSuite =
    describe "ClientDistUpload routing"
        [ test "with no staged distClients entry, is a no-op" <|
            \_ ->
                let
                    ( m, _ ) =
                        update (distUploadMsg "c1" "u1" "f.dmg" 0 True) baseModel
                in
                m |> Expect.equal baseModel
        , test "with a mismatched uuid, is a no-op" <|
            \_ ->
                let
                    staged =
                        { baseModel | distClients = Dict.singleton "c1" (AwaitingUpload { uuid = "other-uuid", platform = "mac" }) }

                    ( m, _ ) =
                        update (distUploadMsg "c1" "u1" "f.dmg" 0 True) staged
                in
                m.registry |> Expect.equal staged.registry
        , test "a non-final chunk writes without touching the registry or clearing the stage" <|
            \_ ->
                let
                    staged =
                        { baseModel | distClients = Dict.singleton "c1" (AwaitingUpload { uuid = "u1", platform = "mac" }) }

                    ( m, _ ) =
                        update (distUploadMsg "c1" "u1" "f.dmg" 0 False) staged
                in
                Expect.all
                    [ \mm -> mm.registry |> Expect.equal staged.registry
                    , \mm -> Dict.get "c1" mm.distClients |> Expect.notEqual Nothing
                    ]
                    m
        , test "the final chunk adds a new registry entry and clears the stage" <|
            \_ ->
                let
                    staged =
                        { baseModel | distClients = Dict.singleton "c1" (AwaitingUpload { uuid = "u3", platform = "mac" }) }

                    ( m, _ ) =
                        update (distUploadMsg "c1" "u3" "f3.dmg" 1 True) staged
                in
                Expect.all
                    [ \mm -> mm.registry |> List.map .uuid |> List.member "u3" |> Expect.equal True
                    , \mm -> Dict.get "c1" mm.distClients |> Expect.equal Nothing
                    ]
                    m
        ]


distCompleteMsg : String -> String -> String -> Msg
distCompleteMsg clientId uuid filename =
    MessageReceived
        { clientId = clientId
        , payload =
            clientEnvelope "distComplete"
                [ ( "uuid", Encode.string uuid )
                , ( "filename", Encode.string filename )
                , ( "winText", Encode.string "gg" )
                , ( "quizQuestions", encodeTestQuestions [ Question [ "a" ] ] )
                ]
        , now = 0
        }


distCompleteSuite : Test
distCompleteSuite =
    describe "ClientDistComplete routing"
        [ test "with no staged distClients entry, is a no-op" <|
            \_ ->
                let
                    ( m, _ ) =
                        update (distCompleteMsg "c1" "u1" "f.dmg") baseModel
                in
                m |> Expect.equal baseModel
        , test "with a mismatched uuid, is a no-op" <|
            \_ ->
                let
                    staged =
                        { baseModel | distClients = Dict.singleton "c1" (AwaitingUpload { uuid = "other-uuid", platform = "mac" }) }

                    ( m, _ ) =
                        update (distCompleteMsg "c1" "u1" "f.dmg") staged
                in
                m.registry |> Expect.equal staged.registry
        , test "a matching completion adds the entry with its winText/quizQuestions and clears the stage" <|
            \_ ->
                let
                    staged =
                        { baseModel | distClients = Dict.singleton "c1" (AwaitingUpload { uuid = "u4", platform = "win" }) }

                    ( m, _ ) =
                        update (distCompleteMsg "c1" "u4" "f4.exe") staged

                    newEntry =
                        m.registry |> List.filter (\e -> e.uuid == "u4") |> List.head
                in
                Expect.all
                    [ \_ -> newEntry |> Maybe.map .winText |> Expect.equal (Just "gg")
                    , \_ ->
                        newEntry
                            |> Maybe.andThen .quizQuestions
                            |> Expect.equal (Just (encodeTestQuestions [ Question [ "a" ] ]))
                    , \_ -> Dict.get "c1" m.distClients |> Expect.equal Nothing
                    ]
                    ()
        ]


distReplaceCompleteMsg : String -> String -> String -> String -> Msg
distReplaceCompleteMsg clientId newUuid oldUuid filename =
    MessageReceived
        { clientId = clientId
        , payload =
            clientEnvelope "distReplaceComplete"
                [ ( "newUuid", Encode.string newUuid )
                , ( "oldUuid", Encode.string oldUuid )
                , ( "filename", Encode.string filename )

                -- Deliberately distinct from entry/baseQuizQuestions' values (winText "",
                -- Alpha/Beta/Gamma) so tests can tell "freshly sent" apart from "inherited".
                , ( "winText", Encode.string "new reward text" )
                , ( "quizQuestions", encodeTestQuestions [ Question [ "replaced answer" ] ] )
                ]
        , now = 0
        }


distReplaceCompleteSuite : Test
distReplaceCompleteSuite =
    describe "ClientDistReplaceComplete routing"
        [ test "with no staged distClients entry, is a no-op" <|
            \_ ->
                let
                    ( m, _ ) =
                        update (distReplaceCompleteMsg "c1" "new1" "uuid1" "f.dmg") baseModel
                in
                m |> Expect.equal baseModel
        , test "with a mismatched newUuid, is a no-op" <|
            \_ ->
                let
                    staged =
                        { baseModel | distClients = Dict.singleton "c1" (AwaitingUpload { uuid = "other-uuid", platform = "mac" }) }

                    ( m, _ ) =
                        update (distReplaceCompleteMsg "c1" "new1" "uuid1" "f.dmg") staged
                in
                m.registry |> Expect.equal staged.registry
        , test "a matching replacement carries the old entry's iqTimer to the new uuid and locks it pending" <|
            \_ ->
                let
                    withIqTimer =
                        baseModel.registry
                            |> List.map
                                (\e ->
                                    if e.uuid == "uuid1" then
                                        { e | iqTimer = Just (encodeIqTimerStateFull { iqState | phase = IqIdleNotStarted }) }

                                    else
                                        e
                                )

                    staged =
                        { baseModel
                            | registry = withIqTimer
                            , distClients = Dict.singleton "c1" (AwaitingUpload { uuid = "new1", platform = "mac" })
                            , connectedPlayers = Dict.singleton "uuid1" "player-client"
                        }

                    ( m, _ ) =
                        update (distReplaceCompleteMsg "c1" "new1" "uuid1" "f-new.dmg") staged

                    newEntry =
                        m.registry |> List.filter (\e -> e.uuid == "new1") |> List.head
                in
                Expect.all
                    [ \_ -> newEntry |> Maybe.map .pendingStateEdit |> Expect.equal (Just True)
                    , \_ ->
                        newEntry
                            |> Maybe.andThen .iqTimer
                            |> Expect.equal (withIqTimer |> List.filter (\e -> e.uuid == "uuid1") |> List.head |> Maybe.andThen .iqTimer)
                    , \_ -> m.registry |> List.map .uuid |> List.member "uuid1" |> Expect.equal False
                    , \_ -> Dict.get "uuid1" m.connectedPlayers |> Expect.equal Nothing
                    , \_ -> Set.member "new1" m.pendingStateEdits |> Expect.equal True
                    ]
                    ()
        , test "a matching replacement uses the freshly-sent winText/quizQuestions, not the old entry's" <|
            \_ ->
                let
                    staged =
                        { baseModel
                            | distClients = Dict.singleton "c1" (AwaitingUpload { uuid = "new1", platform = "mac" })
                        }

                    ( m, _ ) =
                        update (distReplaceCompleteMsg "c1" "new1" "uuid1" "f-new.dmg") staged

                    newEntry =
                        m.registry |> List.filter (\e -> e.uuid == "new1") |> List.head
                in
                Expect.all
                    [ \_ -> newEntry |> Maybe.map .winText |> Expect.equal (Just "new reward text")
                    , \_ ->
                        newEntry
                            |> Maybe.andThen .quizQuestions
                            |> Expect.equal (Just (encodeTestQuestions [ Question [ "replaced answer" ] ]))
                    ]
                    ()
        , test "a matching replacement still carries quizProgress forward from the old entry (unlike winText/quizQuestions)" <|
            \_ ->
                let
                    withProgress =
                        baseModel.registry
                            |> List.map (\e -> if e.uuid == "uuid1" then { e | quizProgress = 2 } else e)

                    staged =
                        { baseModel
                            | registry = withProgress
                            , distClients = Dict.singleton "c1" (AwaitingUpload { uuid = "new1", platform = "mac" })
                        }

                    ( m, _ ) =
                        update (distReplaceCompleteMsg "c1" "new1" "uuid1" "f-new.dmg") staged

                    newEntry =
                        m.registry |> List.filter (\e -> e.uuid == "new1") |> List.head
                in
                newEntry |> Maybe.map .quizProgress |> Expect.equal (Just 2)
        ]


fileReadSuite : Test
fileReadSuite =
    describe "FileRead routing"
        [ test "a path other than the registry file is a no-op" <|
            \_ ->
                let
                    ( m, _ ) =
                        update (FileRead "some/other/path" (Ok "contents")) baseModel
                in
                m |> Expect.equal baseModel
        , test "a registry read failure is a no-op" <|
            \_ ->
                let
                    ( m, _ ) =
                        update (FileRead registryFilePath (Err "ENOENT")) baseModel
                in
                m |> Expect.equal baseModel
        , test "a successful registry read parses entries and rehydrates pendingStateEdits/iqTimers" <|
            \_ ->
                let
                    savedIqTimer =
                        encodeIqTimerStateFull { iqState | phase = IqCounting, countdownRemaining = 9 }

                    row1 =
                        Encode.encode 0
                            (Encode.object
                                [ ( "builds"
                                  , Encode.list identity
                                        [ Encode.object
                                            [ ( "uuid", Encode.string "u1" )
                                            , ( "filename", Encode.string "f1.dmg" )
                                            , ( "platform", Encode.string "mac" )
                                            , ( "state", Encode.null )
                                            , ( "pendingStateEdit", Encode.bool True )
                                            , ( "iqTimer", savedIqTimer )
                                            ]
                                        ]
                                  )
                                ]
                            )

                    ( m, _ ) =
                        update (FileRead registryFilePath (Ok row1)) baseModel
                in
                Expect.all
                    [ \mm -> mm.registry |> List.map .uuid |> Expect.equal [ "u1" ]
                    , \mm -> Set.member "u1" mm.pendingStateEdits |> Expect.equal True
                    , \mm -> Dict.get "u1" mm.iqTimers |> Maybe.map .countdownRemaining |> Expect.equal (Just 9)
                    ]
                    m
        ]


iqStartCountdownMsg : String -> Msg
iqStartCountdownMsg clientId =
    iqTimerMsg clientId "iqStartCountdown"


iqStartCountdownSuite : Test
iqStartCountdownSuite =
    describe "ClientIqStartCountdown routing"
        [ test "an unconnected clientId is a no-op" <|
            \_ ->
                let
                    ( m, _ ) =
                        update (iqStartCountdownMsg "c1") baseModel
                in
                m |> Expect.equal baseModel
        , test "no existing iqTimer entry starts a fresh countdown" <|
            \_ ->
                let
                    staged =
                        { baseModel | connectedPlayers = Dict.singleton "uuid1" "c1" }

                    ( m, _ ) =
                        update (iqStartCountdownMsg "c1") staged
                in
                Dict.get "uuid1" m.iqTimers |> Maybe.map .phase |> Expect.equal (Just IqCounting)
        , test "an IqIdleCaught entry (post-catch, waiting to restart) starts a fresh countdown" <|
            \_ ->
                let
                    staged =
                        { baseModel
                            | connectedPlayers = Dict.singleton "uuid1" "c1"
                            , iqTimers = Dict.singleton "uuid1" { iqState | phase = IqIdleCaught, totalDings = 200 }
                        }

                    ( m, _ ) =
                        update (iqStartCountdownMsg "c1") staged
                in
                Expect.all
                    [ \_ -> Dict.get "uuid1" m.iqTimers |> Maybe.map .phase |> Expect.equal (Just IqCounting)
                    , \_ -> Dict.get "uuid1" m.iqTimers |> Maybe.map .totalDings |> Expect.equal (Just 200)
                    ]
                    ()
        , test "an IqIdleNotStarted entry (e.g. after an admin edit) starts a fresh countdown" <|
            \_ ->
                let
                    staged =
                        { baseModel
                            | connectedPlayers = Dict.singleton "uuid1" "c1"
                            , iqTimers = Dict.singleton "uuid1" { iqState | phase = IqIdleNotStarted, totalDings = 200 }
                        }

                    ( m, _ ) =
                        update (iqStartCountdownMsg "c1") staged
                in
                Expect.all
                    [ \_ -> Dict.get "uuid1" m.iqTimers |> Maybe.map .phase |> Expect.equal (Just IqCounting)
                    , \_ -> Dict.get "uuid1" m.iqTimers |> Maybe.map .totalDings |> Expect.equal (Just 200)
                    ]
                    ()
        , test "a live entry mid-test (e.g. IqCounting) is left untouched, not restarted" <|
            \_ ->
                let
                    staged =
                        { baseModel
                            | connectedPlayers = Dict.singleton "uuid1" "c1"
                            , iqTimers = Dict.singleton "uuid1" { iqState | phase = IqCounting, countdownRemaining = 5 }
                        }

                    ( m, cmd ) =
                        update (iqStartCountdownMsg "c1") staged
                in
                Expect.all
                    [ \_ -> Dict.get "uuid1" m.iqTimers |> Expect.equal (Just { iqState | phase = IqCounting, countdownRemaining = 5 })
                    , \_ -> cmd |> Expect.equal Cmd.none
                    ]
                    ()
        , test "a live entry mid-ding (IqDingShown) is left untouched, not restarted" <|
            \_ ->
                let
                    staged =
                        { baseModel
                            | connectedPlayers = Dict.singleton "uuid1" "c1"
                            , iqTimers = Dict.singleton "uuid1" { iqState | phase = IqDingShown }
                        }

                    ( m, cmd ) =
                        update (iqStartCountdownMsg "c1") staged
                in
                Expect.all
                    [ \_ -> Dict.get "uuid1" m.iqTimers |> Expect.equal (Just { iqState | phase = IqDingShown })
                    , \_ -> cmd |> Expect.equal Cmd.none
                    ]
                    ()
        ]


iqReadyForDingMsg : String -> Msg
iqReadyForDingMsg clientId =
    iqTimerMsg clientId "iqReadyForDing"


iqReadyForDingSuite : Test
iqReadyForDingSuite =
    describe "ClientIqReadyForDing routing"
        [ test "an unconnected clientId is a no-op" <|
            \_ ->
                let
                    ( m, _ ) =
                        update (iqReadyForDingMsg "c1") baseModel
                in
                m |> Expect.equal baseModel
        , test "a connected uuid with no iqTimer entry is a no-op" <|
            \_ ->
                let
                    staged =
                        { baseModel | connectedPlayers = Dict.singleton "uuid1" "c1" }

                    ( m, _ ) =
                        update (iqReadyForDingMsg "c1") staged
                in
                m.iqTimers |> Expect.equal Dict.empty
        , test "IqAwaitingReady arms the first ding" <|
            \_ ->
                let
                    staged =
                        { baseModel
                            | connectedPlayers = Dict.singleton "uuid1" "c1"
                            , iqTimers = Dict.singleton "uuid1" { iqState | phase = IqAwaitingReady }
                        }

                    ( m, _ ) =
                        update (iqReadyForDingMsg "c1") staged
                in
                Dict.get "uuid1" m.iqTimers |> Maybe.map .phase |> Expect.equal (Just IqDingScheduled)
        , test "IqDingShown resolving to Completed clears the timer" <|
            \_ ->
                let
                    staged =
                        { baseModel
                            | connectedPlayers = Dict.singleton "uuid1" "c1"
                            , iqTimers = Dict.singleton "uuid1" { iqState | phase = IqDingShown, lastDing = RealDing, dingCount = IQTest.iqQuestionCount - 1, totalDings = IQTest.iqQuestionCount }
                        }

                    ( m, _ ) =
                        update (iqReadyForDingMsg "c1") staged
                in
                Dict.get "uuid1" m.iqTimers |> Expect.equal Nothing
        , test "IqDingShown resolving to Advanced arms the next ding" <|
            \_ ->
                let
                    staged =
                        { baseModel
                            | connectedPlayers = Dict.singleton "uuid1" "c1"
                            , iqTimers = Dict.singleton "uuid1" { iqState | phase = IqDingShown, lastDing = RealDing, dingCount = 0, totalDings = IQTest.iqQuestionCount }
                        }

                    ( m, _ ) =
                        update (iqReadyForDingMsg "c1") staged
                in
                Dict.get "uuid1" m.iqTimers |> Maybe.map (\s -> ( s.phase, s.dingCount )) |> Expect.equal (Just ( IqDingScheduled, 1 ))
        , test "a stale request in an unrelated phase (e.g. still counting down) is ignored" <|
            \_ ->
                let
                    staged =
                        { baseModel
                            | connectedPlayers = Dict.singleton "uuid1" "c1"
                            , iqTimers = Dict.singleton "uuid1" { iqState | phase = IqCounting, countdownRemaining = 5 }
                        }

                    ( m, _ ) =
                        update (iqReadyForDingMsg "c1") staged
                in
                Dict.get "uuid1" m.iqTimers |> Expect.equal (Just { iqState | phase = IqCounting, countdownRemaining = 5 })
        ]


resumeIqTimerSuite : Test
resumeIqTimerSuite =
    describe "resumeIqTimer (via ClientIqResume)"
        [ test "no iqTimer entry at all is a no-op" <|
            \_ ->
                let
                    staged =
                        { baseModel | connectedPlayers = Dict.singleton "uuid1" "c1" }

                    ( m, _ ) =
                        update (iqTimerMsg "c1" "iqResume") staged
                in
                m.iqTimers |> Expect.equal Dict.empty
        , test "IqAwaitingReady re-arms the next ding" <|
            \_ ->
                let
                    staged =
                        { baseModel
                            | connectedPlayers = Dict.singleton "uuid1" "c1"
                            , iqTimers = Dict.singleton "uuid1" { iqState | phase = IqAwaitingReady }
                        }

                    ( m, _ ) =
                        update (iqTimerMsg "c1" "iqResume") staged
                in
                Dict.get "uuid1" m.iqTimers |> Maybe.map .phase |> Expect.equal (Just IqDingScheduled)
        , test "IqDingScheduled re-arms the pending ding" <|
            \_ ->
                let
                    staged =
                        { baseModel
                            | connectedPlayers = Dict.singleton "uuid1" "c1"
                            , iqTimers = Dict.singleton "uuid1" { iqState | phase = IqDingScheduled }
                        }

                    ( m, _ ) =
                        update (iqTimerMsg "c1" "iqResume") staged
                in
                Dict.get "uuid1" m.iqTimers |> Maybe.map .phase |> Expect.equal (Just IqDingScheduled)
        , test "resumeIqTimer directly: an unconnected player's disconnected sendToPlayer is still a safe no-op Cmd" <|
            \_ ->
                let
                    staged =
                        { baseModel | iqTimers = Dict.singleton "uuid1" { iqState | phase = IqDingShown } }

                    ( m, _ ) =
                        resumeIqTimer "uuid1" staged
                in
                m |> Expect.equal staged
        ]


countdownStepSuite : Test
countdownStepSuite =
    describe "CountdownStep routing"
        [ test "no iqTimer entry at all is a no-op" <|
            \_ ->
                let
                    ( m, _ ) =
                        update (CountdownStep { uuid = "uuid1", epoch = 1 }) baseModel
                in
                m.iqTimers |> Expect.equal Dict.empty
        , test "a matching tick decrements the countdown" <|
            \_ ->
                let
                    staged =
                        { baseModel | iqTimers = Dict.singleton "uuid1" { iqState | epoch = 1, phase = IqCounting, countdownRemaining = 5 } }

                    ( m, _ ) =
                        update (CountdownStep { uuid = "uuid1", epoch = 1 }) staged
                in
                Dict.get "uuid1" m.iqTimers |> Maybe.map (\s -> ( s.countdownRemaining, s.phase )) |> Expect.equal (Just ( 4, IqCounting ))
        , test "reaching zero completes the countdown into IqAwaitingReady" <|
            \_ ->
                let
                    staged =
                        { baseModel | iqTimers = Dict.singleton "uuid1" { iqState | epoch = 1, phase = IqCounting, countdownRemaining = 1 } }

                    ( m, _ ) =
                        update (CountdownStep { uuid = "uuid1", epoch = 1 }) staged
                in
                Dict.get "uuid1" m.iqTimers |> Maybe.map (\s -> ( s.countdownRemaining, s.phase )) |> Expect.equal (Just ( 0, IqAwaitingReady ))
        , test "a disconnected player's countdown still ticks (sendToPlayer safely no-ops)" <|
            \_ ->
                let
                    staged =
                        { baseModel | iqTimers = Dict.singleton "uuid1" { iqState | epoch = 1, phase = IqCounting, countdownRemaining = 5 } }

                    ( m, _ ) =
                        update (CountdownStep { uuid = "uuid1", epoch = 1 }) staged
                in
                Dict.get "uuid1" m.iqTimers |> Maybe.map .countdownRemaining |> Expect.equal (Just 4)
        ]


dingReadySuite : Test
dingReadySuite =
    describe "DingReady routing"
        [ test "no iqTimer entry at all is a no-op" <|
            \_ ->
                let
                    ( m, _ ) =
                        update (DingReady { uuid = "uuid1", epoch = 1 }) baseModel
                in
                m.iqTimers |> Expect.equal Dict.empty
        , test "a matching fire classifies and shows the next ding" <|
            \_ ->
                let
                    state =
                        { iqState | epoch = 1, phase = IqDingScheduled, dingCount = 5, fakeFlashPoint = 999 }

                    staged =
                        { baseModel | iqTimers = Dict.singleton "uuid1" state, seed = Random.initialSeed 42 }

                    ( coin, _ ) =
                        Random.step IQTest.coinFlipGen (Random.initialSeed 42)

                    expectedKind =
                        classifyDing coin state

                    ( m, _ ) =
                        update (DingReady { uuid = "uuid1", epoch = 1 }) staged
                in
                Dict.get "uuid1" m.iqTimers
                    |> Maybe.map (\s -> ( s.phase, s.lastDing ))
                    |> Expect.equal (Just ( IqDingShown, expectedKind ))
        ]


iqPhaseDingKindCodecSuite : Test
iqPhaseDingKindCodecSuite =
    describe "decodeIqPhase / decodeDingKind full coverage"
        [ test "round-trips every IqPhase via the full state codec" <|
            \_ ->
                let
                    roundTrip phase =
                        encodeIqTimerStateFull { iqState | phase = phase }
                            |> Decode.decodeValue decodeIqTimerStateFull
                            |> Result.map .phase
                in
                [ IqCounting, IqAwaitingReady, IqDingScheduled, IqDingShown, IqIdleNotStarted, IqIdleCaught ]
                    |> List.map roundTrip
                    |> Expect.equal (List.map Ok [ IqCounting, IqAwaitingReady, IqDingScheduled, IqDingShown, IqIdleNotStarted, IqIdleCaught ])
        , test "decodes the legacy pre-split \"IqIdle\" tag as IqIdleNotStarted" <|
            \_ ->
                encodeIqTimerStateFull { iqState | phase = IqIdleCaught }
                    |> Encode.encode 0
                    |> String.replace "\"IqIdleCaught\"" "\"IqIdle\""
                    |> Decode.decodeString decodeIqTimerStateFull
                    |> Result.map .phase
                    |> Expect.equal (Ok IqIdleNotStarted)
        , test "round-trips every DingKind via the full state codec" <|
            \_ ->
                let
                    roundTrip kind =
                        encodeIqTimerStateFull { iqState | lastDing = kind }
                            |> Decode.decodeValue decodeIqTimerStateFull
                            |> Result.map .lastDing
                in
                [ RealDing, TrapFake, PhaseFake ]
                    |> List.map roundTrip
                    |> Expect.equal (List.map Ok [ RealDing, TrapFake, PhaseFake ])
        , test "decodeIqPhase rejects an unknown phase string" <|
            \_ -> Decode.decodeString decodeIqPhase "\"NotAPhase\"" |> Result.toMaybe |> Expect.equal Nothing
        , test "decodeDingKind rejects an unknown kind string" <|
            \_ -> Decode.decodeString decodeDingKind "\"NotAKind\"" |> Result.toMaybe |> Expect.equal Nothing
        ]


editedIqBeginSuite : Test
editedIqBeginSuite =
    describe "edit:state can reset iqTimer back to IqIdleNotStarted directly"
        [ test "saving iqTimer with phase IqIdleNotStarted and the edited totalDings lands as-is" <|
            \_ ->
                let
                    editing =
                        { baseModel | distClients = Dict.singleton "c1" (EditingState "uuid1") }

                    editedState =
                        encodeServerStateFields
                            { winText = ""
                            , iqTimer = Just (encodeIqTimerStateFull { iqState | phase = IqIdleNotStarted, totalDings = 250 })
                            , quizProgress = 0
                            , timerEndsAt = Nothing
                            , quizQuestions = Nothing
                            }

                    ( m, _ ) =
                        update (saveMsg "c1" "uuid1" (Encode.encode 0 editedState)) editing
                in
                Dict.get "uuid1" m.iqTimers
                    |> Maybe.map (\s -> ( s.totalDings, s.phase ))
                    |> Expect.equal (Just ( 250, IqIdleNotStarted ))
        ]


distRegisterMsg : String -> String -> String -> Msg
distRegisterMsg clientId uuid platform =
    MessageReceived
        { clientId = clientId
        , payload = clientEnvelope "distRegister" [ ( "uuid", Encode.string uuid ), ( "platform", Encode.string platform ) ]
        , now = 0
        }


distStateEditMsg : String -> String -> Msg
distStateEditMsg clientId uuid =
    MessageReceived { clientId = clientId, payload = clientEnvelope "distStateEdit" [ ( "uuid", Encode.string uuid ) ], now = 0 }


distListMsg : String -> Msg
distListMsg clientId =
    MessageReceived { clientId = clientId, payload = clientEnvelope "distList" [], now = 0 }


remainingRoutingSuite : Test
remainingRoutingSuite =
    describe "remaining update routing for full branch coverage"
        [ test "distRegister stages AwaitingAuth and requests admin auth" <|
            \_ ->
                let
                    ( m, _ ) =
                        update (distRegisterMsg "c1" "u5" "mac") baseModel
                in
                Dict.get "c1" m.distClients |> Expect.equal (Just (AwaitingAuth { uuid = "u5", platform = "mac" }))
        , test "distStateEdit stages AwaitingStateEditAuth and requests admin auth" <|
            \_ ->
                let
                    ( m, _ ) =
                        update (distStateEditMsg "c1" "uuid1") baseModel
                in
                Dict.get "c1" m.distClients |> Expect.equal (Just (AwaitingStateEditAuth "uuid1"))
        , test "distList stages AwaitingListAuth and requests admin auth" <|
            \_ ->
                let
                    ( m, _ ) =
                        update (distListMsg "c1") baseModel
                in
                Dict.get "c1" m.distClients |> Expect.equal (Just AwaitingListAuth)
        , test "undeploying a build with a currently-connected player also closes their connection" <|
            \_ ->
                let
                    staged =
                        { baseModel
                            | distClients = Dict.singleton "c1" (AwaitingUndeployAuth "uuid1")
                            , connectedPlayers = Dict.singleton "uuid1" "player-client"
                        }

                    ( m, _ ) =
                        update (authDone "c1" True 2) staged
                in
                Expect.all
                    [ \mm -> registryUuids mm |> Expect.equal [ "uuid2" ]
                    , \mm -> Dict.get "uuid1" mm.connectedPlayers |> Expect.equal Nothing
                    ]
                    m
        , test "undeploying a uuid that isn't in the registry still acks without crashing" <|
            \_ ->
                let
                    staged =
                        { baseModel | distClients = Dict.singleton "c1" (AwaitingUndeployAuth "no-such-uuid") }

                    ( m, _ ) =
                        update (authDone "c1" True 2) staged
                in
                registryUuids m |> Expect.equal [ "uuid1", "uuid2" ]
        , test "opening a build's state for editing with a currently-connected player also closes their connection" <|
            \_ ->
                let
                    staged =
                        { baseModel
                            | distClients = Dict.singleton "c1" (AwaitingStateEditAuth "uuid1")
                            , connectedPlayers = Dict.singleton "uuid1" "player-client"
                        }

                    ( m, _ ) =
                        update (authDone "c1" True 2) staged
                in
                Set.member "uuid1" m.pendingStateEdits |> Expect.equal True
        , test "failed auth for a pending state-edit request closes the admin connection" <|
            \_ ->
                let
                    staged =
                        { baseModel | distClients = Dict.singleton "c1" (AwaitingStateEditAuth "uuid1") }

                    ( m, _ ) =
                        update (authDone "c1" False 0) staged
                in
                Dict.get "c1" m.distClients |> Expect.equal Nothing
        , test "a replacement with no currently-connected old player still succeeds" <|
            \_ ->
                let
                    staged =
                        { baseModel | distClients = Dict.singleton "c1" (AwaitingUpload { uuid = "new1", platform = "mac" }) }

                    ( m, _ ) =
                        update (distReplaceCompleteMsg "c1" "new1" "uuid1" "f-new.dmg") staged
                in
                m.registry |> List.map .uuid |> List.member "new1" |> Expect.equal True
        , test "iqStartCountdown from an unconnected clientId is a no-op" <|
            \_ ->
                let
                    ( m, _ ) =
                        update (iqTimerMsg "unconnected-client" "iqStartCountdown") baseModel
                in
                m.iqTimers |> Expect.equal Dict.empty
        , test "restarting a countdown after a previous run preserves totalDings and bumps the epoch" <|
            \_ ->
                let
                    staged =
                        { baseModel
                            | connectedPlayers = Dict.singleton "uuid1" "c1"
                            , iqTimers = Dict.singleton "uuid1" { iqState | epoch = 3, totalDings = 250, questionIdx = 2, phase = IqIdleCaught }
                        }

                    ( m, _ ) =
                        update (iqTimerMsg "c1" "iqStartCountdown") staged
                in
                Dict.get "uuid1" m.iqTimers
                    |> Maybe.map (\s -> ( s.epoch, s.totalDings, s.questionIdx ))
                    |> Expect.equal (Just ( 4, 250, 2 ))
        , test "the 4th real ding cleared arms the loud gag alongside the next ding" <|
            \_ ->
                let
                    staged =
                        { baseModel
                            | connectedPlayers = Dict.singleton "uuid1" "c1"
                            , iqTimers = Dict.singleton "uuid1" { iqState | phase = IqDingShown, lastDing = RealDing, dingCount = 3, totalDings = IQTest.iqQuestionCount }
                        }

                    ( m, _ ) =
                        update (iqReadyForDingMsg "c1") staged
                in
                Dict.get "uuid1" m.iqTimers |> Maybe.map .dingCount |> Expect.equal (Just 4)
        , test "iqCaught for a connected player with no iqTimer entry is a no-op" <|
            \_ ->
                let
                    staged =
                        { baseModel | connectedPlayers = Dict.singleton "uuid1" "c1" }

                    ( m, _ ) =
                        update (iqTimerMsg "c1" "iqCaught") staged
                in
                m.iqTimers |> Expect.equal Dict.empty
        , test "iqResume from an unconnected clientId is a no-op" <|
            \_ ->
                let
                    ( m, _ ) =
                        update (iqTimerMsg "unconnected-client" "iqResume") baseModel
                in
                m |> Expect.equal baseModel
        , test "an unrecognized MessageReceived payload is a no-op" <|
            \_ ->
                let
                    ( m, _ ) =
                        update (MessageReceived { clientId = "c1", payload = clientEnvelope "somethingElse" [], now = 0 }) baseModel
                in
                m |> Expect.equal baseModel
        ]


classifyFileReadSuite : Test
classifyFileReadSuite =
    describe "classifyFileRead"
        [ test "contents present maps to a successful FileRead" <|
            \_ ->
                classifyFileRead { path = "p", contents = Just "data", error = Nothing }
                    |> Expect.equal (FileRead "p" (Ok "data"))
        , test "an error with no contents maps to a failed FileRead" <|
            \_ ->
                classifyFileRead { path = "p", contents = Nothing, error = Just "boom" }
                    |> Expect.equal (FileRead "p" (Err "boom"))
        , test "neither contents nor error falls back to a generic failure" <|
            \_ ->
                classifyFileRead { path = "p", contents = Nothing, error = Nothing }
                    |> Expect.equal (FileRead "p" (Err "unknown error"))
        ]


-- ── Quiz-progress win gating ─────────────────────────────────────────────────
-- The server no longer trusts the freeform client-reported `state.screen` to
-- decide when to grant winText (see the removed stateIsWin); it only trusts an
-- explicit, monotonic sequence of quizAdvanced events. See Server.elm's
-- acceptQuizAdvance/quizJustCompleted and Model.quizProgress/totalQuestions.


quizAdvancedMsg : String -> Int -> Msg
quizAdvancedMsg clientId idx =
    MessageReceived
        { clientId = clientId
        , payload = clientEnvelope "quizAdvanced" [ ( "idx", Encode.int idx ) ]
        , now = 0
        }


quizProgressLogicSuite : Test
quizProgressLogicSuite =
    describe "quiz-progress win gating"
        [ describe "acceptQuizAdvance"
            [ test "accepts idx == current, advancing by one" <|
                \_ -> acceptQuizAdvance { current = 0, idx = 0 } |> Expect.equal (Just 1)
            , test "rejects a replayed idx (idx < current)" <|
                \_ -> acceptQuizAdvance { current = 2, idx = 1 } |> Expect.equal Nothing
            , test "rejects a skip-ahead idx (idx > current)" <|
                \_ -> acceptQuizAdvance { current = 0, idx = 2 } |> Expect.equal Nothing
            ]
        , describe "quizJustCompleted"
            [ test "true once next reaches total" <|
                \_ -> quizJustCompleted { next = 3, total = 3 } |> Expect.equal True
            , test "false while next is short of total" <|
                \_ -> quizJustCompleted { next = 2, total = 3 } |> Expect.equal False
            , test "false when total is unset/unreadable (0), even at next = 0" <|
                \_ -> quizJustCompleted { next = 0, total = 0 } |> Expect.equal False
            ]
        , test "decodeClientEnvelope decodes quizAdvanced into ClientQuizAdvanced idx" <|
            \_ ->
                Decode.decodeValue decodeClientEnvelope (clientEnvelope "quizAdvanced" [ ( "idx", Encode.int 2 ) ])
                    |> Expect.equal (Ok (ClientQuizAdvanced 2))
        ]


quizProgressRoutingSuite : Test
quizProgressRoutingSuite =
    describe "quiz-progress message routing in Server.update"
        [ test "a quizAdvanced event advances the player's tracked progress" <|
            \_ ->
                let
                    connected =
                        { baseModel | connectedPlayers = Dict.singleton "uuid1" "c1" }

                    ( m, _ ) =
                        update (quizAdvancedMsg "c1" 0) connected
                in
                Dict.get "uuid1" m.quizProgress |> Expect.equal (Just 1)
        , test "in-order events advance one at a time up to totalQuestions" <|
            \_ ->
                let
                    connected =
                        { baseModel | connectedPlayers = Dict.singleton "uuid1" "c1" }

                    ( afterFirst, _ ) =
                        update (quizAdvancedMsg "c1" 0) connected

                    ( afterSecond, _ ) =
                        update (quizAdvancedMsg "c1" 1) afterFirst

                    ( afterThird, _ ) =
                        update (quizAdvancedMsg "c1" 2) afterSecond
                in
                -- baseModel's entries carry 3 questions (baseQuizQuestions), so idx 0,1,2
                -- reaches the total exactly.
                Dict.get "uuid1" afterThird.quizProgress |> Expect.equal (Just 3)
        , test "a skip-ahead idx (out of order) is ignored" <|
            \_ ->
                let
                    connected =
                        { baseModel | connectedPlayers = Dict.singleton "uuid1" "c1" }

                    ( m, _ ) =
                        update (quizAdvancedMsg "c1" 1) connected
                in
                Dict.get "uuid1" m.quizProgress |> Expect.equal Nothing
        , test "a duplicate idx does not double-advance" <|
            \_ ->
                let
                    connected =
                        { baseModel | connectedPlayers = Dict.singleton "uuid1" "c1" }

                    ( afterFirst, _ ) =
                        update (quizAdvancedMsg "c1" 0) connected

                    ( afterDuplicate, _ ) =
                        update (quizAdvancedMsg "c1" 0) afterFirst
                in
                Dict.get "uuid1" afterDuplicate.quizProgress |> Expect.equal (Just 1)
        , test "quizAdvanced with no clientId->uuid mapping is a no-op" <|
            \_ ->
                let
                    ( m, _ ) =
                        update (quizAdvancedMsg "c1" 0) baseModel
                in
                Dict.get "uuid1" m.quizProgress |> Expect.equal Nothing
        , test "progress is persisted into the registry as it advances" <|
            \_ ->
                let
                    connected =
                        { baseModel | connectedPlayers = Dict.singleton "uuid1" "c1" }

                    ( m, _ ) =
                        update (quizAdvancedMsg "c1" 0) connected

                    entryOf =
                        m.registry |> List.filter (\e -> e.uuid == "uuid1") |> List.head
                in
                entryOf |> Maybe.map .quizProgress |> Expect.equal (Just 1)
        , test "quizAdvanced is ignored while the player has a live IQ-timer entry" <|
            \_ ->
                let
                    connected =
                        { baseModel
                            | connectedPlayers = Dict.singleton "uuid1" "c1"
                            , iqTimers = Dict.singleton "uuid1" iqState
                        }

                    ( m, cmd ) =
                        update (quizAdvancedMsg "c1" 0) connected
                in
                Expect.all
                    [ \_ -> Dict.get "uuid1" m.quizProgress |> Expect.equal Nothing
                    , \_ -> cmd |> Expect.equal Cmd.none
                    ]
                    ()
        , test "quizAdvanced is ignored while the player's IQ-timer entry is IqIdleCaught" <|
            \_ ->
                let
                    connected =
                        { baseModel
                            | connectedPlayers = Dict.singleton "uuid1" "c1"
                            , iqTimers = Dict.singleton "uuid1" { iqState | phase = IqIdleCaught }
                        }

                    ( m, cmd ) =
                        update (quizAdvancedMsg "c1" 0) connected
                in
                Expect.all
                    [ \_ -> Dict.get "uuid1" m.quizProgress |> Expect.equal Nothing
                    , \_ -> cmd |> Expect.equal Cmd.none
                    ]
                    ()
        ]


-- ── Quiz-answer server-side validation ───────────────────────────────────────
-- The server, not the client, holds the answers (see questionsForUuid, resolved
-- per connecting player's own RegistryEntry.quizQuestions -- see #77) and decides
-- correctness via Game.Quiz.decideAnswer -- the client never sees an answer (#54/#32).


quizAnswerSubmittedMsg : String -> { idx : Int, answer : String } -> Msg
quizAnswerSubmittedMsg clientId { idx, answer } =
    MessageReceived
        { clientId = clientId
        , payload = clientEnvelope "quizAnswerSubmitted" [ ( "idx", Encode.int idx ), ( "answer", Encode.string answer ) ]
        , now = 0
        }


quizAnswerDecodeSuite : Test
quizAnswerDecodeSuite =
    describe "decodeClientEnvelope decodes quizAnswerSubmitted"
        [ test "into ClientQuizAnswerSubmitted with idx and answer" <|
            \_ ->
                Decode.decodeValue decodeClientEnvelope
                    (clientEnvelope "quizAnswerSubmitted" [ ( "idx", Encode.int 1 ), ( "answer", Encode.string "Beta" ) ])
                    |> Expect.equal (Ok (ClientQuizAnswerSubmitted { idx = 1, answer = "Beta" }))
        ]


quizAnswerResultEnvelopeSuite : Test
quizAnswerResultEnvelopeSuite =
    describe "quizAnswerResultEnvelope"
        [ test "carries idx, correct, and revealAnswer" <|
            \_ ->
                quizAnswerResultEnvelope { idx = 1, correct = False, revealAnswer = "Beta" }
                    |> Encode.encode 0
                    |> Expect.equal """{"payload":"quizAnswerResult","quizAnswerResult":{"idx":1,"correct":false,"revealAnswer":"Beta"}}"""
        ]


quizAnswerRoutingSuite : Test
quizAnswerRoutingSuite =
    describe "quiz-answer message routing in Server.update"
        [ test "a correct answer for the current question advances progress and replies correct=True" <|
            \_ ->
                let
                    connected =
                        { baseModel | connectedPlayers = Dict.singleton "uuid1" "c1" }

                    ( m, _ ) =
                        update (quizAnswerSubmittedMsg "c1" { idx = 0, answer = "alpha" }) connected
                in
                Dict.get "uuid1" m.quizProgress |> Expect.equal (Just 1)
        , test "a correct answer is case/punctuation-insensitive (see normalize)" <|
            \_ ->
                let
                    connected =
                        { baseModel | connectedPlayers = Dict.singleton "uuid1" "c1" }

                    ( m, _ ) =
                        update (quizAnswerSubmittedMsg "c1" { idx = 0, answer = "  ALPHA!! " }) connected
                in
                Dict.get "uuid1" m.quizProgress |> Expect.equal (Just 1)
        , test "an incorrect answer does not advance progress" <|
            \_ ->
                let
                    connected =
                        { baseModel | connectedPlayers = Dict.singleton "uuid1" "c1" }

                    ( m, _ ) =
                        update (quizAnswerSubmittedMsg "c1" { idx = 0, answer = "nope" }) connected
                in
                Dict.get "uuid1" m.quizProgress |> Expect.equal Nothing
        , test "an incorrect answer populates the IQ gate (IqIdleNotStarted at the failed idx) right away, not lazily on iqStartCountdown" <|
            \_ ->
                let
                    connected =
                        { baseModel | connectedPlayers = Dict.singleton "uuid1" "c1" }

                    ( m, _ ) =
                        update (quizAnswerSubmittedMsg "c1" { idx = 0, answer = "nope" }) connected
                in
                Dict.get "uuid1" m.iqTimers
                    |> Maybe.map (\s -> ( s.phase, s.questionIdx ))
                    |> Expect.equal (Just ( IqIdleNotStarted, 0 ))
        , test "the just-populated IQ gate blocks a follow-up submission for the same question until the test completes" <|
            \_ ->
                let
                    connected =
                        { baseModel | connectedPlayers = Dict.singleton "uuid1" "c1" }

                    ( afterWrong, _ ) =
                        update (quizAnswerSubmittedMsg "c1" { idx = 0, answer = "nope" }) connected

                    ( afterRetry, cmd ) =
                        update (quizAnswerSubmittedMsg "c1" { idx = 0, answer = "alpha" }) afterWrong
                in
                Expect.all
                    [ \_ -> Dict.get "uuid1" afterRetry.quizProgress |> Expect.equal Nothing
                    , \_ -> cmd |> Expect.equal Cmd.none
                    ]
                    ()
        , test "the last question's correct answer completes the quiz and grants winText" <|
            \_ ->
                let
                    connected =
                        { baseModel
                            | connectedPlayers = Dict.singleton "uuid1" "c1"
                            , quizProgress = Dict.singleton "uuid1" 2
                        }

                    ( _, cmd ) =
                        update (quizAnswerSubmittedMsg "c1" { idx = 2, answer = "gamma" }) connected
                in
                cmd |> Expect.notEqual Cmd.none
        , test "a skip-ahead idx (out of order) is ignored, progress untouched" <|
            \_ ->
                let
                    connected =
                        { baseModel | connectedPlayers = Dict.singleton "uuid1" "c1" }

                    ( m, _ ) =
                        update (quizAnswerSubmittedMsg "c1" { idx = 1, answer = "beta" }) connected
                in
                Dict.get "uuid1" m.quizProgress |> Expect.equal Nothing
        , test "an idx beyond the loaded question list is ignored" <|
            \_ ->
                let
                    connected =
                        { baseModel
                            | connectedPlayers = Dict.singleton "uuid1" "c1"
                            , quizProgress = Dict.singleton "uuid1" 5
                        }

                    ( m, _ ) =
                        update (quizAnswerSubmittedMsg "c1" { idx = 5, answer = "anything" }) connected
                in
                Dict.get "uuid1" m.quizProgress |> Expect.equal (Just 5)
        , test "quizAnswerSubmitted with no clientId->uuid mapping is a no-op" <|
            \_ ->
                let
                    ( m, _ ) =
                        update (quizAnswerSubmittedMsg "c1" { idx = 0, answer = "alpha" }) baseModel
                in
                Dict.get "uuid1" m.quizProgress |> Expect.equal Nothing
        , test "progress from a correct answer is persisted into the registry" <|
            \_ ->
                let
                    connected =
                        { baseModel | connectedPlayers = Dict.singleton "uuid1" "c1" }

                    ( m, _ ) =
                        update (quizAnswerSubmittedMsg "c1" { idx = 0, answer = "alpha" }) connected

                    entryOf =
                        m.registry |> List.filter (\e -> e.uuid == "uuid1") |> List.head
                in
                entryOf |> Maybe.map .quizProgress |> Expect.equal (Just 1)
        , test "quizAnswerSubmitted is ignored while the player has a live IQ-timer entry" <|
            \_ ->
                let
                    connected =
                        { baseModel
                            | connectedPlayers = Dict.singleton "uuid1" "c1"
                            , iqTimers = Dict.singleton "uuid1" iqState
                        }

                    ( m, cmd ) =
                        update (quizAnswerSubmittedMsg "c1" { idx = 0, answer = "alpha" }) connected
                in
                Expect.all
                    [ \_ -> Dict.get "uuid1" m.quizProgress |> Expect.equal Nothing
                    , \_ -> cmd |> Expect.equal Cmd.none
                    ]
                    ()
        , test "quizAnswerSubmitted is ignored while the player's IQ-timer entry is IqIdleCaught" <|
            \_ ->
                let
                    connected =
                        { baseModel
                            | connectedPlayers = Dict.singleton "uuid1" "c1"
                            , iqTimers = Dict.singleton "uuid1" { iqState | phase = IqIdleCaught }
                        }

                    ( m, cmd ) =
                        update (quizAnswerSubmittedMsg "c1" { idx = 0, answer = "alpha" }) connected
                in
                Expect.all
                    [ \_ -> Dict.get "uuid1" m.quizProgress |> Expect.equal Nothing
                    , \_ -> cmd |> Expect.equal Cmd.none
                    ]
                    ()
        ]



-- ── Quiz-slide screen derivation (the quiz analogue of deriveIqScreen) ────────


deriveQuizScreenSuite : Test
deriveQuizScreenSuite =
    describe "deriveQuizScreen"
        [ test "derives the earned slide's BlankScreen, decodable by Sync's real decoder" <|
            \_ ->
                deriveQuizScreen { progress = 1, total = 3 }
                    |> Maybe.andThen (Decode.decodeValue decodeScreen >> Result.toMaybe)
                    |> Expect.equal (Just (BlankScreen 1))
        , test "progress at total (quiz complete) is not derivable -- the client's WinScreen report stays authoritative" <|
            \_ -> deriveQuizScreen { progress = 3, total = 3 } |> Expect.equal Nothing
        , test "progress past total is not derivable" <|
            \_ -> deriveQuizScreen { progress = 9, total = 3 } |> Expect.equal Nothing
        , test "a negative progress (hand-mangled registry) is not derivable" <|
            \_ -> deriveQuizScreen { progress = -1, total = 3 } |> Expect.equal Nothing
        , test "total 0 (config unread) is never derivable, even at progress 0" <|
            \_ -> deriveQuizScreen { progress = 0, total = 0 } |> Expect.equal Nothing
        ]


deriveWinScreenSuite : Test
deriveWinScreenSuite =
    describe "deriveWinScreen"
        [ test "derives a WinScreen with the real, already-verified text embedded once progress has reached total" <|
            \_ ->
                deriveWinScreen "hello reward" { progress = 3, total = 3 }
                    |> Maybe.andThen (Decode.decodeValue decodeScreen >> Result.toMaybe)
                    |> Expect.equal (Just (WinScreen "hello reward"))
        , test "not derivable while progress is short of total" <|
            \_ -> deriveWinScreen "hello reward" { progress = 2, total = 3 } |> Expect.equal Nothing
        , test "total 0 (config unread) is never derivable, even at progress 0" <|
            \_ -> deriveWinScreen "hello reward" { progress = 0, total = 0 } |> Expect.equal Nothing
        ]


deriveQuizOrWinScreenSuite : Test
deriveQuizOrWinScreenSuite =
    describe "deriveQuizOrWinScreen"
        [ test "derives the earned slide while progress is in range" <|
            \_ ->
                deriveQuizOrWinScreen "hello reward" { progress = 1, total = 3 }
                    |> Maybe.andThen (Decode.decodeValue decodeScreen >> Result.toMaybe)
                    |> Expect.equal (Just (BlankScreen 1))
        , test "falls back to the derived WinScreen (with the real text embedded) once progress reaches total" <|
            \_ ->
                deriveQuizOrWinScreen "hello reward" { progress = 3, total = 3 }
                    |> Maybe.andThen (Decode.decodeValue decodeScreen >> Result.toMaybe)
                    |> Expect.equal (Just (WinScreen "hello reward"))
        ]


deriveTimedOutScreenSuite : Test
deriveTimedOutScreenSuite =
    describe "deriveTimedOutScreen"
        [ test "derives TimedOutScreen once the deadline has passed" <|
            \_ ->
                deriveTimedOutScreen 1000 (entry "uuid1" |> \e -> { e | timerEndsAt = Just 500 })
                    |> Maybe.andThen (Decode.decodeValue decodeScreen >> Result.toMaybe)
                    |> Expect.equal (Just TimedOutScreen)
        , test "not derivable while the deadline hasn't passed yet" <|
            \_ ->
                deriveTimedOutScreen 100 (entry "uuid1" |> \e -> { e | timerEndsAt = Just 500 })
                    |> Expect.equal Nothing
        , test "not derivable when there's no deadline on file yet" <|
            \_ ->
                deriveTimedOutScreen 1000 (entry "uuid1" |> \e -> { e | timerEndsAt = Nothing })
                    |> Expect.equal Nothing
        ]


persistQuizScreenInRegistrySuite : Test
persistQuizScreenInRegistrySuite =
    describe "persistQuizScreenInRegistry"
        [ test "writes the progress counter on the matching uuid" <|
            \_ ->
                persistQuizScreenInRegistry "uuid1" { next = 1, total = 3 } [ entry "uuid1" ]
                    |> List.head
                    |> Maybe.map .quizProgress
                    |> Expect.equal (Just 1)
        , test "the final advance (next == total) still just writes the counter -- the screen is derived fresh at connect time, never cached" <|
            \_ ->
                persistQuizScreenInRegistry "uuid1" { next = 3, total = 3 } [ entry "uuid1" ]
                    |> List.head
                    |> Maybe.map .quizProgress
                    |> Expect.equal (Just 3)
        , test "other entries pass through unaffected" <|
            \_ ->
                persistQuizScreenInRegistry "uuid1" { next = 1, total = 3 } [ entry "uuid1", entry "uuid2" ]
                    |> List.filter (\e -> e.uuid == "uuid2")
                    |> Expect.equal [ entry "uuid2" ]
        ]


quizEditSuite : Test
quizEditSuite =
    describe "edit:state writes quizProgress directly (issue #74)"
        [ test "saving quizProgress lands in both model.quizProgress and the registry" <|
            \_ ->
                let
                    editing =
                        { baseModel | distClients = Dict.singleton "c1" (EditingState "uuid1") }

                    editedState =
                        encodeServerStateFields
                            { winText = ""
                            , iqTimer = Nothing
                            , quizProgress = 2
                            , timerEndsAt = Nothing
                            , quizQuestions = Nothing
                            }

                    ( m, _ ) =
                        update (saveMsg "c1" "uuid1" (Encode.encode 0 editedState)) editing

                    entryOf =
                        m.registry |> List.filter (\e -> e.uuid == "uuid1") |> List.head
                in
                Expect.all
                    [ \_ -> Dict.get "uuid1" m.quizProgress |> Expect.equal (Just 2)
                    , \_ -> entryOf |> Maybe.map .quizProgress |> Expect.equal (Just 2)
                    ]
                    ()
        , test "the admin can set quizProgress to any value directly -- no clamping" <|
            \_ ->
                let
                    editing =
                        { baseModel | distClients = Dict.singleton "c1" (EditingState "uuid1") }

                    editedState =
                        encodeServerStateFields
                            { winText = "", iqTimer = Nothing, quizProgress = 9, timerEndsAt = Nothing, quizQuestions = Nothing }

                    ( m, _ ) =
                        update (saveMsg "c1" "uuid1" (Encode.encode 0 editedState)) editing
                in
                Dict.get "uuid1" m.quizProgress |> Expect.equal (Just 9)
        ]
