#include "Credentials.hpp"

#include <QByteArray>
#include <QString>
#include <QtGlobal>

#ifdef Q_OS_WIN
#  ifndef WIN32_LEAN_AND_MEAN
#    define WIN32_LEAN_AND_MEAN
#  endif
#  include <Windows.h>
#  include <wincred.h>
#  pragma comment(lib, "advapi32.lib")
#endif

#ifdef Q_OS_MACOS
#  include <CoreFoundation/CoreFoundation.h>
#  include <Security/Security.h>
#endif

#ifdef Q_OS_LINUX
#  include <QDir>
#  include <QFileInfo>
#  include <QJsonDocument>
#  include <QJsonObject>
#  include <QJsonParseError>
#  include <QJsonValue>
#  include <QProcess>
#  include <QStringList>
#endif

namespace pslcp::net {
namespace {

// Common identifiers. The Windows ``target`` string matches the Python-side
// ``_CRED_PREFIX + name`` composition; macOS splits into service + account
// (Keychain convention) and Linux uses the bare ``MANAGER_PSK`` key that the
// age-encrypted JSON file is keyed by.
constexpr const char* kCredentialService = "PolySignalLab";
constexpr const char* kCredentialName = "MANAGER_PSK";
constexpr int kMinKeyBytes = 32;

QByteArray hexDecode(const QString& hex, bool& ok)
{
    QByteArray out;
    out.reserve(hex.size() / 2);
    int acc = 0;
    int nibble_count = 0;
    for (QChar ch : hex) {
        const ushort c = ch.unicode();
        int v;
        if (c >= '0' && c <= '9') v = c - '0';
        else if (c >= 'a' && c <= 'f') v = c - 'a' + 10;
        else if (c >= 'A' && c <= 'F') v = c - 'A' + 10;
        else { ok = false; return {}; }
        acc = (acc << 4) | v;
        nibble_count++;
        if (nibble_count == 2) {
            out.append(static_cast<char>(acc));
            acc = 0;
            nibble_count = 0;
        }
    }
    ok = (nibble_count == 0);
    return out;
}

// Decode + length-check a hex-string credential value into a CredentialResult.
// ``hexString`` is whatever the per-platform backend produced (trimmed).
CredentialResult buildResult(const QString& hexString)
{
    CredentialResult result;
    bool ok = false;
    const QByteArray key = hexDecode(hexString, ok);
    if (!ok) {
        result.error_message = QStringLiteral("MANAGER_PSK is not valid hex");
        return result;
    }
    if (key.size() < kMinKeyBytes) {
        result.error_message = QStringLiteral("MANAGER_PSK is too short (%1 < %2)")
                                   .arg(key.size()).arg(kMinKeyBytes);
        return result;
    }
    result.ok = true;
    result.key_bytes = key;
    return result;
}

// ---------------------------------------------------------------------------
// Windows — Credential Manager
// ---------------------------------------------------------------------------

#ifdef Q_OS_WIN

CredentialResult fetchFromStore()
{
    CredentialResult result;
    const QString target =
        QString::fromUtf8(kCredentialService) + QStringLiteral("/") +
        QString::fromUtf8(kCredentialName);
    const std::wstring target_w = target.toStdWString();

    PCREDENTIALW cred = nullptr;
    if (!::CredReadW(target_w.c_str(), CRED_TYPE_GENERIC, 0, &cred)) {
        const DWORD err = ::GetLastError();
        result.error_message =
            QStringLiteral("Credential %1 not found (Win32 error %2). "
                           "Run `pslagent store-manager-psk <hex>` on this machine.")
                .arg(target).arg(err);
        return result;
    }
    const QString hex = QString::fromUtf8(
        reinterpret_cast<const char*>(cred->CredentialBlob),
        static_cast<int>(cred->CredentialBlobSize)).trimmed();
    ::CredFree(cred);
    return buildResult(hex);
}

#endif // Q_OS_WIN

// ---------------------------------------------------------------------------
// macOS — Keychain Services (GenericPassword)
// ---------------------------------------------------------------------------

#ifdef Q_OS_MACOS

// RAII guard for CoreFoundation refs. Ensures release on all early-return paths.
template <typename T>
class CFRef {
public:
    explicit CFRef(T ref = nullptr) : ref_(ref) {}
    ~CFRef() { if (ref_) CFRelease(ref_); }
    CFRef(const CFRef&) = delete;
    CFRef& operator=(const CFRef&) = delete;
    T get() const { return ref_; }
    T release() { T r = ref_; ref_ = nullptr; return r; }
private:
    T ref_;
};

CredentialResult fetchFromStore()
{
    CredentialResult result;

    CFRef<CFStringRef> service(CFStringCreateWithCString(
        kCFAllocatorDefault, kCredentialService, kCFStringEncodingUTF8));
    CFRef<CFStringRef> account(CFStringCreateWithCString(
        kCFAllocatorDefault, kCredentialName, kCFStringEncodingUTF8));
    if (!service.get() || !account.get()) {
        result.error_message = QStringLiteral("Keychain query: CFString alloc failed");
        return result;
    }

    const void* keys[]   = { kSecClass, kSecAttrService, kSecAttrAccount,
                             kSecReturnData, kSecMatchLimit };
    const void* values[] = { kSecClassGenericPassword, service.get(), account.get(),
                             kCFBooleanTrue, kSecMatchLimitOne };
    CFRef<CFDictionaryRef> query(CFDictionaryCreate(
        kCFAllocatorDefault, keys, values, 5,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks));
    if (!query.get()) {
        result.error_message = QStringLiteral("Keychain query: dict alloc failed");
        return result;
    }

    CFTypeRef raw = nullptr;
    const OSStatus status = SecItemCopyMatching(query.get(), &raw);
    CFRef<CFTypeRef> result_ref(raw);
    if (status != errSecSuccess) {
        result.error_message = QStringLiteral(
            "Keychain item service=%1 account=%2 not found (OSStatus %3). "
            "Run `pslagent store-manager-psk <hex>` on this machine.")
            .arg(QString::fromUtf8(kCredentialService))
            .arg(QString::fromUtf8(kCredentialName))
            .arg(static_cast<long>(status));
        return result;
    }

    // kSecReturnData + kSecClassGenericPassword → CFDataRef payload.
    if (CFGetTypeID(result_ref.get()) != CFDataGetTypeID()) {
        result.error_message = QStringLiteral("Keychain returned unexpected type");
        return result;
    }
    CFDataRef data = static_cast<CFDataRef>(result_ref.get());
    const CFIndex length = CFDataGetLength(data);
    const UInt8* bytes = CFDataGetBytePtr(data);
    const QString hex = QString::fromUtf8(
        reinterpret_cast<const char*>(bytes),
        static_cast<int>(length)).trimmed();
    return buildResult(hex);
}

#endif // Q_OS_MACOS

// ---------------------------------------------------------------------------
// Linux — age-encrypted secrets file (SSH host key identity)
// ---------------------------------------------------------------------------
//
// Mirrors PolySignalLab/PolyTraderLightning/shared/keystore.py:
//   1. Find the machine's best SSH host key (ed25519 > ecdsa > rsa) under
//      /etc/ssh/ssh_host_<type>_key. Public half must exist; private half
//      must be readable by the current process.
//   2. Decrypt ~/.config/polysignallab/secrets.age via
//      ``age -d -i <priv_key> <secrets_file>``.
//   3. Parse the plaintext as JSON, pick the ``MANAGER_PSK`` string value.
//
// No Python-side env-var legacy fallback is wired here — keys.py
// deliberately doesn't pass ``env_var`` when loading MANAGER_PSK, so we
// don't either. Panel Linux users must land the secret in the age file.

#ifdef Q_OS_LINUX

namespace {

constexpr int kAgeTimeoutMs = 10000;

QString detectSshHostKey()
{
    const QStringList key_types = {
        QStringLiteral("ed25519"),
        QStringLiteral("ecdsa"),
        QStringLiteral("rsa"),
    };
    for (const QString& type : key_types) {
        const QString priv = QStringLiteral("/etc/ssh/ssh_host_%1_key").arg(type);
        const QString pub = priv + QStringLiteral(".pub");
        QFileInfo pub_info(pub);
        QFileInfo priv_info(priv);
        if (!pub_info.exists()) continue;
        if (!priv_info.isReadable()) continue;
        return priv;
    }
    return {};
}

QString ageSecretsFilePath()
{
    // Match shared.keystore._DEFAULT_SECRETS_PATH exactly.
    return QDir::homePath() + QStringLiteral("/.config/polysignallab/secrets.age");
}

} // namespace

CredentialResult fetchFromStore()
{
    CredentialResult result;

    const QString priv_key = detectSshHostKey();
    if (priv_key.isEmpty()) {
        result.error_message = QStringLiteral(
            "No readable SSH host key found in /etc/ssh/ "
            "(tried ed25519, ecdsa, rsa). age backend unavailable on this host.");
        return result;
    }

    const QString secrets_file = ageSecretsFilePath();
    if (!QFileInfo(secrets_file).exists()) {
        result.error_message = QStringLiteral(
            "age secrets file not found at %1. "
            "Run `pslagent store-manager-psk <hex>` to create it.")
            .arg(secrets_file);
        return result;
    }

    QProcess proc;
    proc.start(QStringLiteral("age"),
               {QStringLiteral("-d"), QStringLiteral("-i"), priv_key, secrets_file});
    if (!proc.waitForStarted(5000)) {
        result.error_message = QStringLiteral(
            "Failed to launch 'age' binary (is it on PATH?). "
            "Install age for encrypted secrets storage.");
        return result;
    }
    if (!proc.waitForFinished(kAgeTimeoutMs)) {
        proc.kill();
        proc.waitForFinished(1000);
        result.error_message = QStringLiteral("age decrypt timed out after %1ms")
                                   .arg(kAgeTimeoutMs);
        return result;
    }
    if (proc.exitStatus() != QProcess::NormalExit || proc.exitCode() != 0) {
        const QString stderr_str =
            QString::fromUtf8(proc.readAllStandardError()).trimmed();
        result.error_message = QStringLiteral("age decrypt failed: %1").arg(stderr_str);
        return result;
    }

    const QByteArray plaintext = proc.readAllStandardOutput();
    QJsonParseError parse_err;
    const QJsonDocument doc = QJsonDocument::fromJson(plaintext, &parse_err);
    if (parse_err.error != QJsonParseError::NoError || !doc.isObject()) {
        result.error_message = QStringLiteral(
            "age secrets file contains invalid JSON: %1")
            .arg(parse_err.errorString());
        return result;
    }

    const QJsonValue val =
        doc.object().value(QString::fromUtf8(kCredentialName));
    if (!val.isString()) {
        result.error_message = QStringLiteral(
            "MANAGER_PSK not found in age secrets file at %1").arg(secrets_file);
        return result;
    }
    return buildResult(val.toString().trimmed());
}

#endif // Q_OS_LINUX

// ---------------------------------------------------------------------------
// Fallback for any platform we haven't coded for (future BSDs, etc.)
// ---------------------------------------------------------------------------

#if !defined(Q_OS_WIN) && !defined(Q_OS_MACOS) && !defined(Q_OS_LINUX)
CredentialResult fetchFromStore()
{
    CredentialResult result;
    result.error_message = QStringLiteral(
        "No credential backend implemented for this platform.");
    return result;
}
#endif

} // namespace

CredentialResult loadManagerPsk()
{
    return fetchFromStore();
}

} // namespace pslcp::net
