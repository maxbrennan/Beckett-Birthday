module ServerTest exposing (..)

import Dict
import Expect
import Json.Decode as Decode
import Json.Encode as Encode
import Server exposing (Model, Msg(..), update)
import Server.Distribution exposing (DistStage(..))
import Server.Protocol
    exposing
        ( ClientEnvelope(..)
        , ackEnvelope
        , ackWithUploadTokenEnvelope
        , decodeClientEnvelope
        , distListResultEnvelope
        )
import Server.Registry exposing (RegistryEntry, snapshotForJeopardy)
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
    }


baseModel : Model
baseModel =
    { connectedPlayers = Dict.empty
    , distClients = Dict.empty
    , registry = [ entry "uuid1", entry "uuid2" ]
    , pendingStateEdits = Set.empty
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
