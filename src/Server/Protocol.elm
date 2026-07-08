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
    | ClientDistComplete { uuid : String, filename : String, winText : String }
    | ClientDistStateEdit String
    | ClientDistStateEditSave { uuid : String, json : String }
    | ClientDistReplaceComplete { newUuid : String, oldUuid : String, filename : String }
    | ClientDistUndeploy String
    | ClientDistList
    | ClientIqStartCountdown
    | ClientIqReadyForDing
    | ClientIqCaught
    | ClientIqResume
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
                        Decode.map3 (\u f w -> ClientDistComplete { uuid = u, filename = f, winText = w })
                            (Decode.at [ "distComplete", "uuid" ] Decode.string)
                            (Decode.at [ "distComplete", "filename" ] Decode.string)
                            -- older deploy clients omit winText; codec defaults it to "".
                            (Decode.oneOf [ Decode.at [ "distComplete", "winText" ] Decode.string, Decode.succeed "" ])

                    "distStateEdit" ->
                        Decode.map ClientDistStateEdit
                            (Decode.at [ "distStateEdit", "uuid" ] Decode.string)

                    "distStateEditSave" ->
                        Decode.map2 (\u j -> ClientDistStateEditSave { uuid = u, json = j })
                            (Decode.at [ "distStateEditSave", "uuid" ] Decode.string)
                            (Decode.at [ "distStateEditSave", "json" ] Decode.string)

                    "distReplaceComplete" ->
                        Decode.map3
                            (\n o f -> ClientDistReplaceComplete { newUuid = n, oldUuid = o, filename = f })
                            (Decode.at [ "distReplaceComplete", "newUuid" ] Decode.string)
                            (Decode.at [ "distReplaceComplete", "oldUuid" ] Decode.string)
                            (Decode.at [ "distReplaceComplete", "filename" ] Decode.string)

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


-- Dedicated message carrying the player's win text. Sent only when the incoming state
-- sync shows the player is winning (see stateIsWin), so the text reaches the client at
-- win time without ever living in the client bundle.
winTextEnvelope : String -> Encode.Value
winTextEnvelope text =
    Encode.object
        [ ( "payload", Encode.string "winText" )
        , ( "winText", Encode.object [ ( "text", Encode.string text ) ] )
        ]


-- True when an opaque player-state value represents (or is transitioning into) the
-- win screen. The client reveals the win screen only on the winText message, so we look
-- at the top-level screen tag and, when it is a CheckingAnswerScreen/ConfirmingAnswerScreen
-- wrapper, the nested nextScreen tag, to spot the pending WinScreen.
stateIsWin : Encode.Value -> Bool
stateIsWin state =
    let
        tagAt path =
            Decode.decodeValue (Decode.at path Decode.string) state
                |> Result.withDefault ""

        topTag =
            tagAt [ "screen", "tag" ]
    in
    if topTag == "WinScreen" then
        True

    else if topTag == "CheckingAnswerScreen" || topTag == "ConfirmingAnswerScreen" then
        tagAt [ "screen", "nextScreen", "tag" ] == "WinScreen"

    else
        False


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
