module Server.Protocol exposing (..)

import Json.Decode as Decode
import Json.Encode as Encode
import Server.Distribution exposing (DistInfo)
import Server.Registry exposing (RegistryEntry)


type ClientEnvelope
    = ClientStateUpdate Encode.Value
    | ClientStateRequest String
    | ClientDistRegister DistInfo
    | ClientDistUpload { uuid : String, filename : String, contentsBase64 : String, chunkIndex : Int, isLast : Bool }
    | ClientDistComplete { uuid : String, filename : String, winText : String, quizQuestions : Encode.Value }
    | ClientDistStateEdit String
    | ClientDistStateEditSave { uuid : String, json : String }
    | ClientDistReplaceComplete { newUuid : String, oldUuid : String, filename : String, quizQuestions : Encode.Value, winText : String }
    | ClientDistUndeploy String
    | ClientDistList
    | ClientIqStartCountdown
    | ClientIqReadyForDing
    | ClientIqCaught
    | ClientIqResume
    | ClientQuizAdvanced Int
    | ClientQuizAnswerSubmitted { idx : Int, answer : String }
    | ClientQuizSongEnded Int
    | ClientUnknown


decodeClientEnvelope : Decode.Decoder ClientEnvelope
decodeClientEnvelope =
    Decode.field "payload" Decode.string
        |> Decode.andThen
            (\variant ->
                case variant of
                    "stateUpdate" ->
                        Decode.at [ "stateUpdate", "json" ] Decode.string
                            |> Decode.andThen
                                (\inner ->
                                    case Decode.decodeString Decode.value inner of
                                        Ok v ->
                                            Decode.succeed (ClientStateUpdate v)

                                        Err _ ->
                                            Decode.succeed ClientUnknown
                                )

                    "stateRequest" ->
                        Decode.map ClientStateRequest
                            (Decode.at [ "stateRequest", "uuid" ] Decode.string)

                    "distRegister" ->
                        Decode.map2 (\u p -> ClientDistRegister { uuid = u, platform = p })
                            (Decode.at [ "distRegister", "uuid" ] Decode.string)
                            (Decode.at [ "distRegister", "platform" ] Decode.string)

                    "distUpload" ->
                        Decode.map5
                            (\u f c idx last ->
                                ClientDistUpload
                                    { uuid = u
                                    , filename = f
                                    , contentsBase64 = c
                                    , chunkIndex = idx
                                    , isLast = last
                                    }
                            )
                            (Decode.at [ "distUpload", "uuid" ] Decode.string)
                            (Decode.at [ "distUpload", "filename" ] Decode.string)
                            (Decode.at [ "distUpload", "contents" ] Decode.string)
                            (Decode.at [ "distUpload", "chunkIndex" ] Decode.int)
                            (Decode.at [ "distUpload", "isLast" ] Decode.bool)

                    "distComplete" ->
                        Decode.map4
                            (\u f w q -> ClientDistComplete { uuid = u, filename = f, winText = w, quizQuestions = q })
                            (Decode.at [ "distComplete", "uuid" ] Decode.string)
                            (Decode.at [ "distComplete", "filename" ] Decode.string)
                            -- older deploy clients omit winText; codec defaults it to "".
                            (Decode.oneOf [ Decode.at [ "distComplete", "winText" ] Decode.string, Decode.succeed "" ])
                            -- older deploy clients omit quizQuestions; codec defaults it to [].
                            (Decode.oneOf
                                [ Decode.at [ "distComplete", "quizQuestions" ] Decode.value
                                , Decode.succeed (Encode.list identity [])
                                ]
                            )

                    "distStateEdit" ->
                        Decode.map ClientDistStateEdit
                            (Decode.at [ "distStateEdit", "uuid" ] Decode.string)

                    "distStateEditSave" ->
                        Decode.map2 (\u j -> ClientDistStateEditSave { uuid = u, json = j })
                            (Decode.at [ "distStateEditSave", "uuid" ] Decode.string)
                            (Decode.at [ "distStateEditSave", "json" ] Decode.string)

                    "distReplaceComplete" ->
                        Decode.map5
                            (\n o f q w ->
                                ClientDistReplaceComplete
                                    { newUuid = n, oldUuid = o, filename = f, quizQuestions = q, winText = w }
                            )
                            (Decode.at [ "distReplaceComplete", "newUuid" ] Decode.string)
                            (Decode.at [ "distReplaceComplete", "oldUuid" ] Decode.string)
                            (Decode.at [ "distReplaceComplete", "filename" ] Decode.string)
                            -- older deploy clients omit quizQuestions; codec defaults it to [].
                            (Decode.oneOf
                                [ Decode.at [ "distReplaceComplete", "quizQuestions" ] Decode.value
                                , Decode.succeed (Encode.list identity [])
                                ]
                            )
                            -- older deploy clients omit winText; codec defaults it to "".
                            (Decode.oneOf [ Decode.at [ "distReplaceComplete", "winText" ] Decode.string, Decode.succeed "" ])

                    "distUndeploy" ->
                        Decode.map ClientDistUndeploy
                            (Decode.at [ "distUndeploy", "uuid" ] Decode.string)

                    "distList" ->
                        Decode.succeed ClientDistList

                    "iqStartCountdown" ->
                        Decode.succeed ClientIqStartCountdown

                    "iqReadyForDing" ->
                        Decode.succeed ClientIqReadyForDing

                    "iqCaught" ->
                        Decode.succeed ClientIqCaught

                    "iqResume" ->
                        Decode.succeed ClientIqResume

                    "quizAdvanced" ->
                        Decode.map ClientQuizAdvanced
                            (Decode.at [ "quizAdvanced", "idx" ] Decode.int)

                    "quizAnswerSubmitted" ->
                        Decode.map2 (\idx answer -> ClientQuizAnswerSubmitted { idx = idx, answer = answer })
                            (Decode.at [ "quizAnswerSubmitted", "idx" ] Decode.int)
                            (Decode.at [ "quizAnswerSubmitted", "answer" ] Decode.string)

                    "quizSongEnded" ->
                        Decode.map ClientQuizSongEnded
                            (Decode.at [ "quizSongEnded", "idx" ] Decode.int)

                    _ ->
                        Decode.succeed ClientUnknown
            )


stateEnvelope : Encode.Value -> Encode.Value
stateEnvelope state =
    Encode.object
        [ ( "payload", Encode.string "stateUpdate" )
        , ( "stateUpdate", Encode.object [ ( "json", Encode.string (Encode.encode 0 state) ) ] )
        ]


stateUpdateAckEnvelope : Encode.Value
stateUpdateAckEnvelope =
    Encode.object
        [ ( "payload", Encode.string "stateUpdateAck" )
        , ( "stateUpdateAck", Encode.object [] )
        ]


{-| A marker that tells the JS host to mint and attach an upload token (the
crypto stays in JS). The marker never reaches the protobuf codec:
`sendToClient` in server/index.js rewrites the payload to
`{ distRegisterAck : { uploadToken } }` before encoding.
-}
distRegisterAckEnvelope : Encode.Value
distRegisterAckEnvelope =
    Encode.object
        [ ( "payload", Encode.string "distRegisterAck" )
        , ( "distRegisterAck", Encode.object [ ( "mintUploadToken", Encode.bool True ) ] )
        ]


distUploadAckEnvelope : Encode.Value
distUploadAckEnvelope =
    Encode.object
        [ ( "payload", Encode.string "distUploadAck" )
        , ( "distUploadAck", Encode.object [] )
        ]


distCompleteAckEnvelope : Encode.Value
distCompleteAckEnvelope =
    Encode.object
        [ ( "payload", Encode.string "distCompleteAck" )
        , ( "distCompleteAck", Encode.object [] )
        ]


distStateEditSaveAckEnvelope : Encode.Value
distStateEditSaveAckEnvelope =
    Encode.object
        [ ( "payload", Encode.string "distStateEditSaveAck" )
        , ( "distStateEditSaveAck", Encode.object [] )
        ]


distReplaceCompleteAckEnvelope : Encode.Value
distReplaceCompleteAckEnvelope =
    Encode.object
        [ ( "payload", Encode.string "distReplaceCompleteAck" )
        , ( "distReplaceCompleteAck", Encode.object [] )
        ]


distUndeployAckEnvelope : Encode.Value
distUndeployAckEnvelope =
    Encode.object
        [ ( "payload", Encode.string "distUndeployAck" )
        , ( "distUndeployAck", Encode.object [] )
        ]


distListResultEnvelope : List RegistryEntry -> Encode.Value
distListResultEnvelope entries =
    Encode.object
        [ ( "payload", Encode.string "distListResult" )
        , ( "distListResult"
          , Encode.object
                [ ( "entries"
                  , Encode.list
                        (\e ->
                            Encode.object
                                [ ( "uuid", Encode.string e.uuid )
                                , ( "filename", Encode.string e.filename )
                                , ( "platform", Encode.string e.platform )
                                ]
                        )
                        entries
                  )
                ]
          )
        ]


-- Dedicated message carrying the player's win text. Sent only when the server's own
-- tracked quiz progress (see Server.elm's quizProgress/acceptQuizAdvance/
-- quizJustCompleted) independently confirms the player has passed every question, so
-- the text reaches the client at win time without ever living in the client bundle
-- or being grantable by a self-reported client claim.
winTextEnvelope : String -> Encode.Value
winTextEnvelope text =
    Encode.object
        [ ( "payload", Encode.string "winText" )
        , ( "winText", Encode.object [ ( "text", Encode.string text ) ] )
        ]


-- Delivers the server-established 7-day-session deadline (epoch ms). Sent once per
-- stateRequest, alongside the normal stateUpdate, so the client can render the
-- countdown without ever computing or reporting the deadline itself (see
-- RegistryEntry.timerEndsAt in Server.Registry).
timerSyncEnvelope : Float -> Encode.Value
timerSyncEnvelope timerEndsAt =
    Encode.object
        [ ( "payload", Encode.string "timerSync" )
        , ( "timerSync", Encode.object [ ( "timerEndsAt", Encode.float timerEndsAt ) ] )
        ]


-- Pushed in place of the normal ack/state response once the server's own clock (see
-- Registry.isExpired) confirms this player's deadline has passed -- the server decides
-- the timeout, never the client's own clock.
timedOutEnvelope : Encode.Value
timedOutEnvelope =
    Encode.object
        [ ( "payload", Encode.string "timedOut" )
        , ( "timedOut", Encode.object [] )
        ]


rejectEnvelope : String -> Encode.Value
rejectEnvelope reason =
    Encode.object
        [ ( "payload", Encode.string "stateRequestRejected" )
        , ( "stateRequestRejected", Encode.object [ ( "reason", Encode.string reason ) ] )
        ]


-- ── IQ-test server→client envelopes ─────────────────────────────────────────────
-- The server owns all IQ-test timing and the ding/question count. These carry the
-- server's authoritative view down to the client, which only renders it.


iqCountdownTickEnvelope : Int -> Encode.Value
iqCountdownTickEnvelope remaining =
    Encode.object
        [ ( "payload", Encode.string "iqCountdownTick" )
        , ( "iqCountdownTick", Encode.object [ ( "remaining", Encode.int remaining ) ] )
        ]


iqCountdownCompleteEnvelope : Encode.Value
iqCountdownCompleteEnvelope =
    Encode.object
        [ ( "payload", Encode.string "iqCountdownComplete" )
        , ( "iqCountdownComplete", Encode.object [] )
        ]


iqDingEnvelope : { fake : Bool, trap : Bool, dingCount : Int, totalDings : Int } -> Encode.Value
iqDingEnvelope { fake, trap, dingCount, totalDings } =
    Encode.object
        [ ( "payload", Encode.string "iqDing" )
        , ( "iqDing"
          , Encode.object
                [ ( "fake", Encode.bool fake )
                , ( "trap", Encode.bool trap )
                , ( "dingCount", Encode.int dingCount )
                , ( "totalDings", Encode.int totalDings )
                ]
          )
        ]


iqStartLoudEnvelope : Encode.Value
iqStartLoudEnvelope =
    Encode.object
        [ ( "payload", Encode.string "iqStartLoud" )
        , ( "iqStartLoud", Encode.object [] )
        ]


iqTestCompleteEnvelope : Encode.Value
iqTestCompleteEnvelope =
    Encode.object
        [ ( "payload", Encode.string "iqTestComplete" )
        , ( "iqTestComplete", Encode.object [] )
        ]


-- ── Quiz-answer server→client envelope ──────────────────────────────────────────
-- The server owns answer validation (see Server.elm's ClientQuizAnswerSubmitted
-- handling / Game.Quiz.decideAnswer). revealAnswer is only meaningful when
-- correct = False; the client never learns any other question's answer.


quizAnswerResultEnvelope : { idx : Int, correct : Bool, revealAnswer : String } -> Encode.Value
quizAnswerResultEnvelope { idx, correct, revealAnswer } =
    Encode.object
        [ ( "payload", Encode.string "quizAnswerResult" )
        , ( "quizAnswerResult"
          , Encode.object
                [ ( "idx", Encode.int idx )
                , ( "correct", Encode.bool correct )
                , ( "revealAnswer", Encode.string revealAnswer )
                ]
          )
        ]


-- Confirms the server has recorded that idx's song/video ended, so the client
-- may proceed to reveal the answer input for it (see Server.elm's
-- quizSongEnded tracking / the ClientQuizAnswerSubmitted gate).
quizSongEndedAckEnvelope : Int -> Encode.Value
quizSongEndedAckEnvelope idx =
    Encode.object
        [ ( "payload", Encode.string "quizSongEndedAck" )
        , ( "quizSongEndedAck", Encode.object [ ( "idx", Encode.int idx ) ] )
        ]
