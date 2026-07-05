module Server.Protocol exposing (..)

import Json.Decode as Decode
import Json.Encode as Encode
import Server.Distribution exposing (DistInfo)


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

                    _ ->
                        Decode.succeed ClientUnknown
            )


stateEnvelope : Encode.Value -> Encode.Value
stateEnvelope state =
    Encode.object
        [ ( "payload", Encode.string "stateUpdate" )
        , ( "stateUpdate", Encode.object [ ( "json", Encode.string (Encode.encode 0 state) ) ] )
        ]


ackEnvelope : Encode.Value
ackEnvelope =
    Encode.object
        [ ( "payload", Encode.string "ack" )
        , ( "ack", Encode.object [] )
        ]


-- Ack that also carries the player's win text. Sent only when the incoming state
-- sync shows the player is winning, so the text reaches the client at win time
-- (see stateIsWin) without ever living in the client bundle.
winAckEnvelope : String -> Encode.Value
winAckEnvelope winText =
    Encode.object
        [ ( "payload", Encode.string "ack" )
        , ( "ack", Encode.object [ ( "winText", Encode.string winText ) ] )
        ]


-- True when an opaque player-state value represents (or is transitioning into) the
-- win screen. The win transition is gated on a server ack (CheckingAnswerScreen /
-- ConfirmingAnswerScreen wrap the pending WinScreen), so we look at the top-level
-- screen tag and, when it is one of those wrappers, the nested nextScreen tag.
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
