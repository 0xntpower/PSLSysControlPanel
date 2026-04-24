#pragma once

// Panel-side operator-key derivation (Argon2id via libsodium).
//
// Matches ``pslagent.auth.operator.derive_operator_key`` byte-for-byte:
// Argon2id with the agent's 32-byte salt and the params it advertised in
// ``agent_hello`` (mem_kib / iters / threads). Produces a 32-byte
// ``operator_key`` used as the HMAC-SHA256 key for op_signature on every
// management request.
//
// ``ensureSodium()`` calls ``sodium_init()`` exactly once; safe to invoke
// from multiple call sites.

#include <QByteArray>
#include <QString>

namespace pslcp::net {

struct Argon2idParams {
    int mem_kib = 0;
    int iters = 0;
    int threads = 0;
};

struct OperatorKeyResult {
    bool ok = false;
    QByteArray key;  // 32 bytes on success
    QString error_message;
};

// Initialize libsodium once per process. Returns true on success. If the
// init fails we can't do Argon2id safely, so callers should disable the
// management UI.
bool ensureSodium();

// Derive the 32-byte operator key. Runs the KDF on the calling thread —
// the caller should invoke this off the GUI thread (e.g. via
// ``QtConcurrent::run``) because with production params it takes ~1s.
OperatorKeyResult deriveOperatorKey(const QString& password,
                                     const QByteArray& salt,
                                     const Argon2idParams& params);

} // namespace pslcp::net
