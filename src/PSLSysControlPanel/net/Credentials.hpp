#pragma once

// Read the PSLAgent ``MANAGER_PSK`` from the OS credential store.
//
// Per-platform backend:
//   * Windows  — Credential Manager (DPAPI)   target: PolySignalLab/MANAGER_PSK
//   * macOS    — Keychain GenericPassword     service: PolySignalLab, account: MANAGER_PSK
//   * Linux    — age-encrypted JSON secrets file (~/.config/polysignallab/secrets.age)
//                decrypted with the machine's SSH host key. This mirrors the
//                Python-side ``shared.keystore`` fallback used by PSLAgent and
//                colocated components so the same secrets file is readable
//                from both sides.

#include <QByteArray>
#include <QString>

namespace pslcp::net {

struct CredentialResult {
    bool ok = false;
    QByteArray key_bytes;   // decoded 32-byte PSK on success
    QString error_message;  // human-readable detail when ok == false
};

// Load the PSK, decode from hex to bytes, and return it. On any failure
// (credential missing, malformed hex, too-short) returns ok=false with a
// diagnostic message.
CredentialResult loadManagerPsk();

} // namespace pslcp::net
