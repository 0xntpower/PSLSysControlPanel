#pragma once

// Qt Test classes for the panel's net/ layer. Declared in a header so Qt
// VS Tools' moc picks them up automatically. Implementations live in
// NetTests.cpp alongside the ``main()`` that runs them.

#include <QObject>

class TestCanonicalJson : public QObject {
    Q_OBJECT
private slots:
    void emptyObject();
    void sortsKeysAscii();
    void compactSeparators();
    void nestedObject();
    void arrayOrderPreserved();
    void escapesBackslashAndQuote();
    void escapesControlCharacters();
    void unicodePassesThroughAsUtf8();
};

class TestEnvelope : public QObject {
    Q_OBJECT
private slots:
    void framePrefixIsBigEndianLength();
    void encodeThenDecodeRoundtrip();
    void rejectsWrongPsk();
    void rejectsTamperedPayload();
    void operatorSignaturePresentWhenKeyGiven();
    void operatorSignatureAbsentByDefault();
};
