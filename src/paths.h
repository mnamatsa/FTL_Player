#pragma once

#include <QCoreApplication>
#include <QString>

// Portable layout: everything the app writes lives in the Data folder next to the executable.
namespace Paths {
inline QString app() { return QCoreApplication::applicationDirPath(); }
// FTL_DATA_DIR points test runs at a separate folder.
inline QString data()
{
    const QString dir = qEnvironmentVariable("FTL_DATA_DIR");
    return dir.isEmpty() ? app() + "/Data" : dir;
}
}
