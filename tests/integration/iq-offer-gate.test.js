'use strict';

const registryHelper = require('../helpers/registry');
const { startTestServer } = require('../helpers/testServer');
const { AdminClient } = require('../helpers/adminAuth');
const distClient = require('../helpers/distClient');
const { connectAsPlayer } = require('../helpers/playerClient');
const { waitUntil } = require('../helpers/waitUntil');

const TEST_PORT = 19458;
const USERNAME = 'testadmin';
const PASSWORD = 'correct-horse-battery-staple';
const WIN_TEXT = 'Text "creeper... awwww man" to Max to claim your reward!';

let server;
let admin;

function readRegistry() {
    return registryHelper.readRegistry(server.tempDir);
}

// iqSkipOfferDisabled is a config-time (config/app-config.json's iqSkipOfferEnabled,
// inverted) per-build flag, sent at deploy time like winText/quizQuestions and delivered
// to the client once per stateRequest via the iqOfferGate message (see Server.elm's
// ClientStateRequest handling, Main.elm's ServerIqOfferGate). protobufjs omits a false
// scalar on the wire, so the disabled=true case is the one that must actually be
// exercised end-to-end -- a round-trip test using only the (indistinguishable-from-absent)
// default would never catch a broken wiring of this flag.
describe('IQ-test skip offer gate', () => {
    beforeAll(async () => {
        server = await startTestServer({
            port: TEST_PORT,
            seedUsers: [{ username: USERNAME, password: PASSWORD, level: 2 }],
        });
        admin = new AdminClient({ username: USERNAME, password: PASSWORD });
    }, 20000);

    afterAll(async () => {
        if (server) await server.stop();
    }, 10000);

    test('deploy stores iqOfferDisabled on the registry entry', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'iq-offer-gate-store.dmg',
            winText: WIN_TEXT,
            iqSkipOfferDisabled: true,
        });
        const entry = await waitUntil(() => readRegistry().find((e) => e.uuid === build.uuid));
        expect(entry.iqOfferDisabled).toBe(true);
    });

    test('a build deployed with the offer disabled sends iqOfferGate.disabled = true on connect', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'iq-offer-gate-disabled.dmg',
            winText: WIN_TEXT,
            iqSkipOfferDisabled: true,
        });
        await waitUntil(() => readRegistry().find((e) => e.uuid === build.uuid));

        const { conn } = await connectAsPlayer(TEST_PORT, build.uuid);
        const gate = await conn.waitFor((m) => m.payload === 'iqOfferGate');
        expect(gate.iqOfferGate.disabled).toBe(true);
        await conn.close();
    });

    test('a build deployed without the flag sends iqOfferGate.disabled = false (offer enabled)', async () => {
        const build = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'iq-offer-gate-enabled.dmg',
            winText: WIN_TEXT,
        });
        await waitUntil(() => readRegistry().find((e) => e.uuid === build.uuid));

        const { conn } = await connectAsPlayer(TEST_PORT, build.uuid);
        const gate = await conn.waitFor((m) => m.payload === 'iqOfferGate');
        expect(gate.iqOfferGate.disabled).toBeFalsy();
        await conn.close();
    });

    // Unlike winText's inherit-on-replace behavior, iqOfferDisabled is resent fresh on
    // every replace deploy (see #77's precedent for winText/quizQuestions) -- a replacement
    // build's config may have changed, and silently reusing the old uuid's flag would
    // mismatch the new build.
    test('a replacement build uses the newly-sent iqSkipOfferDisabled value, not the original', async () => {
        const original = await distClient.deployBuild(TEST_PORT, admin, {
            platform: 'mac',
            filename: 'iq-offer-gate-orig.dmg',
            winText: WIN_TEXT,
            iqSkipOfferDisabled: false,
        });
        await waitUntil(() => readRegistry().find((e) => e.uuid === original.uuid));

        const replacement = await distClient.replaceBuild(TEST_PORT, admin, original.uuid, {
            platform: 'mac',
            filename: 'iq-offer-gate-replacement.dmg',
            winText: WIN_TEXT,
            iqSkipOfferDisabled: true,
        });
        const entry = await waitUntil(() => readRegistry().find((e) => e.uuid === replacement.uuid));
        expect(entry.iqOfferDisabled).toBe(true);

        // A replacement starts locked pending an admin state edit (see
        // deploy-replacement.test.js) -- resolve it before a player can connect.
        const { authResult: editAuth, conn: editConn, json } = await distClient.requestStateEdit(TEST_PORT, admin, replacement.uuid);
        expect(editAuth.success).toBe(true);
        await distClient.saveStateEdit(editConn, replacement.uuid, json);
        await editConn.close();
        await waitUntil(() => {
            const found = readRegistry().find((e) => e.uuid === replacement.uuid);
            return found && found.pendingStateEdit === false ? found : null;
        });

        const { conn } = await connectAsPlayer(TEST_PORT, replacement.uuid);
        const gate = await conn.waitFor((m) => m.payload === 'iqOfferGate');
        expect(gate.iqOfferGate.disabled).toBe(true);
        await conn.close();
    }, 10000);
});
