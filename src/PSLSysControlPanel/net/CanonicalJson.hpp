#pragma once

// Canonical-JSON serializer that matches the Python agent's
// ``json.dumps(obj, sort_keys=True, separators=(",", ":"))`` output byte-for-
// byte. Both sides must hash identical bytes or HMAC verification fails,
// so Qt's default ``QJsonDocument::Compact`` (which doesn't sort keys) is
// not usable directly.

#include <QByteArray>
#include <QJsonValue>
#include <QString>

namespace pslcp::net {

// Serialize ``value`` to the canonical JSON bytes used for HMAC input.
// Object keys are sorted ASCIIbetically. No whitespace between tokens.
// String escaping uses the same rules as Python's default json module
// (escapes \, ", and control characters < 0x20; does NOT \uXXXX-escape
// non-ASCII BMP characters — they go through as UTF-8).
QByteArray canonicalJson(const QJsonValue& value);

} // namespace pslcp::net
