#include "CanonicalJson.hpp"

#include <QJsonArray>
#include <QJsonObject>
#include <QStringList>

#include <algorithm>

namespace pslcp::net {
namespace {

void appendEscapedString(QByteArray& out, const QString& str)
{
    out.append('"');
    const QByteArray utf8 = str.toUtf8();
    for (const char c : utf8) {
        const unsigned char u = static_cast<unsigned char>(c);
        switch (c) {
            case '\\': out.append("\\\\", 2); break;
            case '"':  out.append("\\\"", 2); break;
            case '\b': out.append("\\b", 2);  break;
            case '\f': out.append("\\f", 2);  break;
            case '\n': out.append("\\n", 2);  break;
            case '\r': out.append("\\r", 2);  break;
            case '\t': out.append("\\t", 2);  break;
            default:
                if (u < 0x20) {
                    const char hex[] = "0123456789abcdef";
                    char buf[6] = {'\\', 'u', '0', '0', hex[(u >> 4) & 0xF], hex[u & 0xF]};
                    out.append(buf, 6);
                } else {
                    out.append(c);
                }
        }
    }
    out.append('"');
}

void appendNumber(QByteArray& out, double value)
{
    // Match Python's json number formatting for the common cases. Integer
    // values are emitted without a decimal point; floats use repr which Qt's
    // QByteArray::number does close enough for our use. The envelope never
    // carries floats with trailing-zero formatting sensitivity in either
    // side's code path.
    const double rounded = static_cast<double>(static_cast<qint64>(value));
    if (rounded == value && value >= -9.0e15 && value <= 9.0e15) {
        out.append(QByteArray::number(static_cast<qint64>(value)));
    } else {
        out.append(QByteArray::number(value, 'g', 17));
    }
}

void appendValue(QByteArray& out, const QJsonValue& value);

void appendObject(QByteArray& out, const QJsonObject& obj)
{
    out.append('{');
    QStringList keys = obj.keys();
    std::sort(keys.begin(), keys.end());
    bool first = true;
    for (const QString& k : keys) {
        if (!first) {
            out.append(',');
        }
        first = false;
        appendEscapedString(out, k);
        out.append(':');
        appendValue(out, obj.value(k));
    }
    out.append('}');
}

void appendArray(QByteArray& out, const QJsonArray& arr)
{
    out.append('[');
    bool first = true;
    for (const QJsonValue& v : arr) {
        if (!first) {
            out.append(',');
        }
        first = false;
        appendValue(out, v);
    }
    out.append(']');
}

void appendValue(QByteArray& out, const QJsonValue& value)
{
    switch (value.type()) {
        case QJsonValue::Null:
            out.append("null", 4);
            break;
        case QJsonValue::Bool:
            out.append(value.toBool() ? "true" : "false");
            break;
        case QJsonValue::Double:
            appendNumber(out, value.toDouble());
            break;
        case QJsonValue::String:
            appendEscapedString(out, value.toString());
            break;
        case QJsonValue::Array:
            appendArray(out, value.toArray());
            break;
        case QJsonValue::Object:
            appendObject(out, value.toObject());
            break;
        case QJsonValue::Undefined:
            out.append("null", 4);
            break;
    }
}

} // namespace

QByteArray canonicalJson(const QJsonValue& value)
{
    QByteArray out;
    appendValue(out, value);
    return out;
}

} // namespace pslcp::net
