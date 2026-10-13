# Connecting to an AzerothCore realm

Use **External Realm** with WotLK 3.3.5a build 12340 and a normal server account.
The authentication server and world server are separate TCP endpoints. Setting
the server up is
[README.md § Run your own server](../README.md#3-run-your-own-server-azerothcore)
and [§ Connect the client](../README.md#4-connect-the-client-to-your-server);
this file is for a connection that fails.

| Setting | Value to use |
|---|---|
| Login address | Reachable LAN IP or DNS hostname of the authentication server; no `http://`, URL path or port suffix |
| Login port | The configured authserver port; normally `3724`, not the worldserver port |
| World address | The address advertised by the selected realm in the server's `realmlist` table |
| World port | The configured worldserver port; normally `8085` |
| Client build | WotLK 3.3.5a / `12340` |

On a LAN, the server must advertise an address reachable from the **Switch**.
`127.0.0.1` and `localhost` refer to the console itself when received by the
client. Correct the server's advertised realm address settings instead of
forcing every world connection to use the authentication host: those services
may intentionally be hosted on different machines. For Docker deployments,
follow the server guide and leave `localAddress` at its default. Ensure bind
settings and the firewall allow **both** TCP ports on the intended network.

## Where the client saves the server

The address and port you type on the login screen are saved to
`sdmc:/wowps/wowps/.wowps/login.cfg`. In the current **v3** format the host and
port are the `[server host:port]` section header:

```
version=3
active=192.168.2.38:3724

[server 192.168.2.38:3724]
username=yourname
```

The older flat `hostname=` / `port=` keys are migrated into this format
automatically on load. Read or edit this file to check or correct the saved
address and port.

## Locating the failure

- **Cannot connect:** check the address, auth port, server process and network.
  Both TCP `3724` and `8085` must be reachable from the console.
- **Account/password rejected:** check the account on the server. Repeated
  automatic retries are intentionally not used for account rejection.
- **Realm list appears but world connection fails:** inspect the advertised
  realm address/port, the worldserver process, the bind address and the
  firewall.
- **Version/gamebuild mismatch:** the client is WotLK 3.3.5a / `12340`. The
  realm row's `gamebuild` must be `12340` and `Expansion` must be `2`; a realm
  advertising a different build will not accept this client.
- **Server identity verification fails:** the proof did not match. The client
  will not bypass verification; confirm the server/client protocol and retain
  both client and server logs for diagnosis.
- **Disconnect after entering the world:** preserve the logs and record the
  character, zone and action. Authentication success does not establish that
  every gameplay opcode or server module is supported.

The Switch logs are `sdmc:/wowps/wowps/logs/boot.log` and
`sdmc:/wowps/wowps/logs/wowps.log`. Keep them together, and redact account names
and private addresses before posting them publicly; never publish passwords or
saved login hashes.

Server reference: [AzerothCore networking](https://www.azerothcore.org/wiki/networking).
