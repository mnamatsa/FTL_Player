#pragma once

#include <QObject>
#include <QString>
#include <QStringList>
#include <QtQml/qqmlregistration.h>

// The GPU setting: "auto" | "integrated" | "dedicated". Integrated / dedicated are the GPUs Windows itself
// ranks first for power saving / high performance (IDXGIFactory6::EnumAdapterByGpuPreference), so it works
// on any PC; with a single GPU both are that one.
// "auto" plays on Windows' default GPU, unless it can't decode the video's codec in hardware and another GPU
// can (e.g. AV1 on an older integrated GPU): then on that one (high performance first).
namespace Gpus {
struct Adapter {
    QString name;       // e.g. "AMD Radeon(TM) Graphics"
    int index = -1;     // position in DXGI's adapter list (what Qt's QT_D3D_ADAPTER_INDEX means)
};
Adapter forChoice(const QString &choice);      // index -1 for "auto" or when there is none
QString defaultName();                         // the GPU Windows gives an app that doesn't choose ("auto")
// Codecs a GPU decodes in hardware: "h264", "vp9", "av1" (checked once per GPU).
QStringList decodes(const QString &adapterName);
// The GPU to play a video in this codec ("avc1", "vp09", "av01" ...) on with "auto"; "" = Windows' default.
QString autoFor(const QString &codec);
}

// For the settings page: which GPU each choice means on this PC, and what it decodes.
class GpuInfo : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

public:
    explicit GpuInfo(QObject *parent = nullptr) : QObject(parent) {}
    Q_INVOKABLE QString name(const QString &choice) const
    {
        return choice == "auto" ? Gpus::defaultName() : Gpus::forChoice(choice).name;
    }
    // "H.264, VP9, AV1"
    Q_INVOKABLE QString decodes(const QString &choice) const
    {
        QStringList names;
        for (const QString &c : Gpus::decodes(name(choice)))
            names << (c == "h264" ? "H.264" : c.toUpper());
        return names.join(", ");
    }
};
