#include "Envelope.hpp"

#include "CanonicalJson.hpp"

#include <QByteArray>
#include <QDataStream>
#include <QDateTime>
#include <QJsonDocument>
#include <QMessageAuthenticationCode>
#include <QRandomGenerator>

namespace pslcp::net {
namespace {

constexpr int kNonceBytes = 16;

QByteArray hmacSha256Hex(const QByteArray& key, const QByteArray& msg)
{
    QMessageAuthenticationCode mac(QCryptographicHash::Sha256, key);
    mac.addData(msg);
    return mac.result().toHex();
}

bool constantTimeEqualHex(const QByteArray& a, const QByteArray& b)
{
    if (a.size() != b.size()) {
        return false;
    }
    unsigned char diff = 0;
    for (int i = 0; i < a.size(); ++i) {
        diff |= static_cast<unsigned char>(a[i] ^ b[i]);
    }
    return diff == 0;
}

} // namespace

QByteArray freshNonce()
{
    QByteArray bytes(kNonceBytes, 0);
    QRandomGenerator::system()->generate(bytes.data(),
                                         bytes.data() + bytes.size());
    return bytes.toHex();
}

QByteArray nowIso()
{
    const QDateTime now = QDateTime::currentDateTimeUtc();
    const qint64 ms = now.toMSecsSinceEpoch();
    const qint64 seconds = ms / 1000;
    const qint64 us = (ms % 1000) * 1000;
    const QString base = now.toString(QStringLiteral("yyyy-MM-ddTHH:mm:ss"));
    // Python format: microseconds appended with a dot, then +00:00.
    // Note: Qt's UTC datetime doesn't carry microsecond precision — we pad
    // with zeros. That's OK because the server only checks timestamp
    // freshness to ±60s, not microsecond accuracy.
    Q_UNUSED(seconds);
    return QStringLiteral("%1.%2+00:00")
        .arg(base)
        .arg(us, 6, 10, QLatin1Char('0'))
        .toUtf8();
}

QByteArray encodeSignedFrame(const QByteArray& psk, const QJsonObject& inner,
                              const QByteArray& operator_key)
{
    const QByteArray payload_bytes = canonicalJson(inner);
    const QByteArray nonce = freshNonce();

    QByteArray hmac_input;
    hmac_input.reserve(nonce.size() + payload_bytes.size());
    hmac_input.append(nonce);
    hmac_input.append(payload_bytes);
    const QByteArray signature = hmacSha256Hex(psk, hmac_input);

    QJsonObject envelope;
    envelope.insert(QStringLiteral("payload"), QString::fromUtf8(payload_bytes));
    envelope.insert(QStringLiteral("nonce"), QString::fromUtf8(nonce));
    envelope.insert(QStringLiteral("signature"), QString::fromUtf8(signature));
    if (!operator_key.isEmpty()) {
        const QByteArray op_sig = hmacSha256Hex(operator_key, hmac_input);
        envelope.insert(QStringLiteral("op_signature"), QString::fromUtf8(op_sig));
    }

    // Envelope JSON doesn't need to be canonical (only the inner payload
    // is hashed) — use QJsonDocument's compact form for compactness.
    const QByteArray body = QJsonDocument(envelope).toJson(QJsonDocument::Compact);

    QByteArray frame;
    frame.reserve(4 + body.size());
    const quint32 length = static_cast<quint32>(body.size());
    frame.append(static_cast<char>((length >> 24) & 0xFF));
    frame.append(static_cast<char>((length >> 16) & 0xFF));
    frame.append(static_cast<char>((length >> 8) & 0xFF));
    frame.append(static_cast<char>(length & 0xFF));
    frame.append(body);
    return frame;
}

DecodeResult decodeAndVerify(const QByteArray& frame_body, const QByteArray& psk)
{
    DecodeResult result;
    QJsonParseError jerr{};
    const QJsonDocument doc = QJsonDocument::fromJson(frame_body, &jerr);
    if (jerr.error != QJsonParseError::NoError || !doc.isObject()) {
        result.error_message = QStringLiteral("envelope is not a JSON object: %1").arg(jerr.errorString());
        return result;
    }
    const QJsonObject env = doc.object();
    const QString payload_str = env.value(QStringLiteral("payload")).toString();
    const QString nonce = env.value(QStringLiteral("nonce")).toString();
    const QString signature = env.value(QStringLiteral("signature")).toString();
    if (payload_str.isEmpty() || nonce.size() != 32 || signature.size() != 64) {
        result.error_message = QStringLiteral("envelope missing or malformed fields");
        return result;
    }

    QByteArray hmac_input;
    hmac_input.append(nonce.toUtf8());
    hmac_input.append(payload_str.toUtf8());
    const QByteArray expected = hmacSha256Hex(psk, hmac_input);
    if (!constantTimeEqualHex(signature.toUtf8(), expected)) {
        result.error_message = QStringLiteral("PSK signature mismatch");
        return result;
    }

    QJsonParseError perr{};
    const QJsonDocument payload_doc = QJsonDocument::fromJson(payload_str.toUtf8(), &perr);
    if (perr.error != QJsonParseError::NoError || !payload_doc.isObject()) {
        result.error_message = QStringLiteral("payload is not a JSON object: %1").arg(perr.errorString());
        return result;
    }
    const QJsonObject payload_obj = payload_doc.object();
    result.payload.type = payload_obj.value(QStringLiteral("type")).toString();
    result.payload.req_id = payload_obj.value(QStringLiteral("req_id")).toString();
    result.payload.timestamp_iso = payload_obj.value(QStringLiteral("timestamp")).toString();
    if (result.payload.type.isEmpty()) {
        result.error_message = QStringLiteral("payload missing 'type'");
        return result;
    }
    // Body: extract whichever of args/data/error is present.
    for (const QString& key : {QStringLiteral("data"), QStringLiteral("error"), QStringLiteral("args")}) {
        if (payload_obj.contains(key) && payload_obj.value(key).isObject()) {
            result.payload.body = payload_obj.value(key).toObject();
            break;
        }
    }
    result.ok = true;
    return result;
}

} // namespace pslcp::net
