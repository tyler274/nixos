// Fake xTool M2 for testing Studio's Wi-Fi/USB device discovery without the
// real hardware. Wired up as the `xtool-m2-emulator` command by
// xtool-studio.nix; run it on a machine on the same subnet as the PC running
// Studio, then start a scan — a "Fake xTool M2" should appear. It only answers
// the discovery handshake; it does not emulate the job/control protocol.
//
// Protocol reverse-engineered from discover-worker.4a93a1c1.cjs in the 1.7.30
// payload: Studio sends an AES-256-CBC encrypted {type:"deviceFind",
// method:"request"} probe (key = primaryKey, random 16-byte IV prepended) to
// the discovery groups; a device replies to the sender's source port with a
// "...method:response" packet encrypted under commonKey, echoing the requestId.
import dgram from "node:dgram";
import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";
import os from "node:os";

const primaryKey = "makeblockmakeblockmakeblock-2025"; // Studio -> device
const commonKey = "makeblocsdbfjssjkkejqbcsdjfbqlla"; // device -> Studio

const key32 = (k) => {
  const out = Buffer.alloc(32);
  Buffer.from(k, "utf8").copy(out, 0, 0, 32);
  return out;
};

function decrypt(buf, key) {
  const iv = buf.subarray(0, 16);
  const d = createDecipheriv("aes-256-cbc", key32(key), iv);
  return Buffer.concat([d.update(buf.subarray(16)), d.final()]).toString("utf8");
}

function encrypt(text, key) {
  const iv = randomBytes(16);
  const c = createCipheriv("aes-256-cbc", key32(key), iv);
  return Buffer.concat([iv, c.update(text, "utf8"), c.final()]);
}

// First non-internal IPv4 address = the "device IP" we announce.
const lanIP =
  Object.values(os.networkInterfaces())
    .flat()
    .find((a) => a && a.family === "IPv4" && !a.internal)?.address ??
  "127.0.0.1";

function makeResponse(requestId) {
  return JSON.stringify({
    type: "deviceFind",
    method: "response",
    data: {
      version: "1.0",
      requestId,
      ip: lanIP,
      deviceIp: lanIP,
      deviceName: "Fake xTool M2",
      deviceCode: "JS002", // M2 per resources/ext.json
      deviceId: "JS002-EMU-0001",
      deviceSn: "EMUM2000000001",
      key: commonKey,
      netType: "wifi",
      firmwareVersion: "1.0.0",
      platformVersion: "1.0.0",
    },
  });
}

function handle(sock, label) {
  return (msg, rinfo) => {
    let text;
    try {
      text = decrypt(msg, primaryKey);
    } catch {
      return; // not a Studio probe (e.g. real mDNS traffic on 5353)
    }
    let parsed;
    try {
      parsed = JSON.parse(text);
    } catch {
      console.log(`[${label}] decrypted non-JSON from ${rinfo.address}:${rinfo.port}: ${text}`);
      return;
    }
    if (parsed.type !== "deviceFind" || parsed.method !== "request") {
      console.log(`[${label}] ignoring ${parsed.type}/${parsed.method}`);
      return;
    }
    const requestId = parsed.data?.requestId;
    console.log(
      `[${label}] probe from ${rinfo.address}:${rinfo.port} requestId=${requestId} clientType=${parsed.data?.clientType}`
    );
    const reply = encrypt(makeResponse(requestId), commonKey);
    sock.send(reply, 0, reply.length, rinfo.port, rinfo.address, (err) => {
      if (err) console.error(`[${label}] reply failed:`, err.message);
      else console.log(`[${label}] replied as M2 (${lanIP}) to ${rinfo.address}:${rinfo.port}`);
    });
  };
}

// Multicast groups Studio probes, plus the unicast-only port 25454 used by
// the connect-by-IP flow (Studio itself binds 5353/5354/25353/25354 for its
// receivers, so on a same-host test 25454 is the only conflict-free port).
const listeners = [
  { port: 5353, group: "224.0.0.251" },
  { port: 5354, group: "224.0.0.252" },
  { port: 25353, group: "239.0.1.251" },
  { port: 25354, group: "239.0.1.252" },
  { port: 25454, group: null },
];

for (const { port, group } of listeners) {
  const sock = dgram.createSocket({ type: "udp4", reuseAddr: true });
  const label = group ? `${group}:${port}` : `unicast:${port}`;
  sock.on("error", (e) => console.error(`[${label}] socket error:`, e.message));
  sock.on("message", handle(sock, label));
  sock.bind(port, "0.0.0.0", () => {
    if (group) {
      try {
        sock.addMembership(group);
      } catch (e) {
        console.error(`[${label}] join failed:`, e.message);
      }
    }
    console.log(`[${label}] listening`);
  });
}

console.log(`fake M2 emulator: announcing deviceIp=${lanIP}`);
