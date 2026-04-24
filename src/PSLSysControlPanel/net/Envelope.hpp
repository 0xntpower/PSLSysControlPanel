#pragma once

// Encode + decode the PSLAgent signed envelope (spec §4). Mirrors the
// ``pslagent.protocol.envelope`` Python module byte-for-byte so the two
// sides hash identical bytes for HMAC verification.

#include <QByteArray>
#include <QJsonObject>

namespace pslcp::net {

struct Envelope {
    QByteArray payload;       // canonical JSON bytes of the inner payload
    QByteArray nonce_hex;     // 32 hex chars (16 random bytes)
    QByteArray signature_hex; // 64 hex chars (HMAC-SHA256)
    QByteArray op_signature_hex;  // empty when not present
};

struct Payload {
    QString type;
    QString req_id;
    QString timestamp_iso;
    QJsonObject body;  // one of args / data / error, whichever is present
};

// Build a signed envelope and wrap it in the 4-byte length-prefixed frame
// format the agent's transport expects. ``inner`` must include ``type``,
// ``req_id``, ``timestamp`` fields. When ``operator_key`` is non-empty an
// additional ``op_signature`` field is added — required for management
// messages (component_start/stop/restart, config_set, log_tail, etc.).
QByteArray encodeSignedFrame(const QByteArray& psk, const QJsonObject& inner,
                             const QByteArray& operator_key = {});

// Parse a received frame body (header already stripped). Verifies the PSK
// signature. Returns an empty payload + error string on failure.
struct DecodeResult {
    bool ok = false;
    Payload payload;
    QString error_message;
};

DecodeResult decodeAndVerify(const QByteArray& frame_body, const QByteArray& psk);

// 32-hex-char (16 random bytes) nonce via Qt's secure-random RNG.
QByteArray freshNonce();

// ISO-8601 UTC timestamp matching Python's datetime.isoformat() for the
// ``datetime.now(UTC)`` case — e.g. ``2026-04-23T07:18:14.384927+00:00``.
QByteArray nowIso();

} // namespace pslcp::net
