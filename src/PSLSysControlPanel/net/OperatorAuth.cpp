#include "OperatorAuth.hpp"

#include <sodium.h>

#include <QMutex>

namespace pslcp::net {
namespace {

QMutex g_sodium_mutex;
bool g_sodium_ok = false;
bool g_sodium_tried = false;

} // namespace

bool ensureSodium()
{
    QMutexLocker lock(&g_sodium_mutex);
    if (g_sodium_tried) {
        return g_sodium_ok;
    }
    g_sodium_tried = true;
    // sodium_init returns 0 on first successful init, 1 if already initialized,
    // -1 on failure. Either of the first two is OK.
    const int rc = sodium_init();
    g_sodium_ok = (rc >= 0);
    return g_sodium_ok;
}

OperatorKeyResult deriveOperatorKey(const QString& password,
                                     const QByteArray& salt,
                                     const Argon2idParams& params)
{
    OperatorKeyResult result;
    if (!ensureSodium()) {
        result.error_message = QStringLiteral("libsodium not initialized");
        return result;
    }
    // Argon2id salt: libsodium mandates exactly 16 bytes. The agent generates
    // 16-byte salts to match.
    if (salt.size() != 16) {
        result.error_message = QStringLiteral("salt must be 16 bytes, got %1").arg(salt.size());
        return result;
    }
    if (params.mem_kib <= 0 || params.iters <= 0 || params.threads <= 0) {
        result.error_message = QStringLiteral("argon2id params must all be positive");
        return result;
    }
    // libsodium's native Argon2id API uses bytes for memory cost. The agent
    // reports memory in KiB so we multiply by 1024. Similarly ``iters`` is
    // the opslimit and ``threads`` is the parallelism — but libsodium's
    // ``crypto_pwhash_argon2id`` call does NOT expose threads; it pins to 1.
    // We refuse to derive if the agent demands threads != 1 so the two
    // sides never disagree silently.
    if (params.threads != 1) {
        result.error_message = QStringLiteral(
            "agent requested Argon2id threads=%1 but libsodium's API fixes threads=1; "
            "cannot derive matching key"
        ).arg(params.threads);
        return result;
    }

    QByteArray password_bytes = password.toUtf8();
    QByteArray key(32, Qt::Uninitialized);
    const int rc = crypto_pwhash(
        reinterpret_cast<unsigned char*>(key.data()),
        static_cast<unsigned long long>(key.size()),
        password_bytes.constData(),
        static_cast<unsigned long long>(password_bytes.size()),
        reinterpret_cast<const unsigned char*>(salt.constData()),
        static_cast<unsigned long long>(params.iters),
        static_cast<size_t>(params.mem_kib) * 1024ULL,
        crypto_pwhash_ALG_ARGON2ID13);

    // Wipe the password bytes from memory — not perfect (QByteArray's
    // internal buffer may have been reallocated during toUtf8), but our
    // only remaining copy is now scrubbed.
    sodium_memzero(password_bytes.data(), static_cast<size_t>(password_bytes.size()));

    if (rc != 0) {
        // Most common cause: requested memory exceeds system RAM budget.
        result.error_message = QStringLiteral("Argon2id derivation failed (rc=%1)").arg(rc);
        // Don't leave half-derived key material around.
        sodium_memzero(key.data(), static_cast<size_t>(key.size()));
        return result;
    }

    result.ok = true;
    result.key = key;
    return result;
}

} // namespace pslcp::net
