const protobuf = require('protobufjs');
const path = require('path');

const root = protobuf.loadSync(path.join(__dirname, 'proto', 'messages.proto'));
const ServerMessage = root.lookupType('birthday.ServerMessage');
const ClientMessage = root.lookupType('birthday.ClientMessage');

const encode = (Type, payload) =>
    Type.encode(Type.create(payload)).finish();

const decode = (Type, buf) =>
    Type.toObject(Type.decode(buf), { defaults: true, oneofs: true });

module.exports = {
    encodeServer: (msg) => encode(ServerMessage, msg),
    decodeServer: (buf) => decode(ServerMessage, buf),
    encodeClient: (msg) => encode(ClientMessage, msg),
    decodeClient: (buf) => decode(ClientMessage, buf),
};
