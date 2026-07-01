module Server.Protocol exposing (..)

import Json.Decode as Decode
import Json.Encode as Encode
import Server.Distribution exposing (DistInfo)


type ClientEnvelope
    = ClientStateUpdate Encode.Value
    | ClientStateRequest String
    | ClientDistRegister DistInfo
    | ClientDistUpload { uuid : String, filename : String, contentsBase64 : String, chunkIndex : Int, isLast : Bool }
    | ClientDistComplete { uuid : String, filename : String }
    | ClientDistStateEdit String
    | ClientDistStateEditSave { uuid : String, json : String }
    | ClientDistReplaceComplete { newUuid : String, oldUuid : String, filename : String }
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
                        Decode.map2 (\u f -> ClientDistComplete { uuid = u, filename = f })
                            (Decode.at [ "distComplete", "uuid" ] Decode.string)
                            (Decode.at [ "distComplete", "filename" ] Decode.string)

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


rejectEnvelope : String -> Encode.Value
rejectEnvelope reason =
    Encode.object
        [ ( "payload", Encode.string "stateRequestRejected" )
        , ( "stateRequestRejected", Encode.object [ ( "reason", Encode.string reason ) ] )
        ]
