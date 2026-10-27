#include "gpus.h"

#ifdef Q_OS_WIN
#include <windows.h>
#include <dxgi1_6.h>
#include <d3d11.h>
#include <initguid.h>
#endif

#include <QHash>

Gpus::Adapter Gpus::forChoice(const QString &choice)
{
    Adapter result;
#ifdef Q_OS_WIN
    if (choice != "integrated" && choice != "dedicated")
        return result;
    // tests: behave like a PC with one GPU (both choices give the power-saving one)
    const bool oneGpu = qEnvironmentVariableIsSet("FTL_TEST_ONE_GPU");
    IDXGIFactory6 *factory = nullptr;
    if (FAILED(CreateDXGIFactory1(__uuidof(IDXGIFactory6), reinterpret_cast<void **>(&factory))))
        return result;
    const DXGI_GPU_PREFERENCE pref = choice == "dedicated" && !oneGpu ? DXGI_GPU_PREFERENCE_HIGH_PERFORMANCE
                                                           : DXGI_GPU_PREFERENCE_MINIMUM_POWER;
    LUID wanted = {};
    for (UINT i = 0;; ++i) {        // the first hardware adapter in that order
        IDXGIAdapter1 *a = nullptr;
        if (FAILED(factory->EnumAdapterByGpuPreference(i, pref, __uuidof(IDXGIAdapter1), reinterpret_cast<void **>(&a))))
            break;
        DXGI_ADAPTER_DESC1 d;
        const bool ok = SUCCEEDED(a->GetDesc1(&d)) && !(d.Flags & DXGI_ADAPTER_FLAG_SOFTWARE);
        a->Release();
        if (ok) {
            result.name = QString::fromWCharArray(d.Description);
            wanted = d.AdapterLuid;
            break;
        }
    }
    // its position in the plain adapter list
    for (UINT i = 0; !result.name.isEmpty(); ++i) {
        IDXGIAdapter1 *a = nullptr;
        if (FAILED(factory->EnumAdapters1(i, &a)))
            break;
        DXGI_ADAPTER_DESC1 d;
        const bool same = SUCCEEDED(a->GetDesc1(&d)) && d.AdapterLuid.LowPart == wanted.LowPart
                          && d.AdapterLuid.HighPart == wanted.HighPart;
        a->Release();
        if (same) {
            result.index = int(i);
            break;
        }
    }
    factory->Release();
#else
    Q_UNUSED(choice);
#endif
    return result;
}

// The first adapter in DXGI's list: what Direct3D uses when no adapter is named (mpv and Qt with "auto").
// Windows puts the one chosen for the app in its own graphics settings first.
QString Gpus::defaultName()
{
    QString name;
#ifdef Q_OS_WIN
    IDXGIFactory1 *factory = nullptr;
    if (FAILED(CreateDXGIFactory1(__uuidof(IDXGIFactory1), reinterpret_cast<void **>(&factory))))
        return name;
    IDXGIAdapter1 *a = nullptr;
    if (SUCCEEDED(factory->EnumAdapters1(0, &a))) {
        DXGI_ADAPTER_DESC1 d;
        if (SUCCEEDED(a->GetDesc1(&d)))
            name = QString::fromWCharArray(d.Description);
        a->Release();
    }
    factory->Release();
#endif
    return name;
}

#ifdef Q_OS_WIN
// DXVA decoder profiles (8-bit): H.264, VP9 profile 0, AV1 profile 0
DEFINE_GUID(FTL_PROFILE_H264, 0x1b81be68, 0xa0c7, 0x11d3, 0xb9, 0x84, 0x00, 0xc0, 0x4f, 0x2e, 0x73, 0xc5);
DEFINE_GUID(FTL_PROFILE_VP9, 0x463707f8, 0xa1d0, 0x4585, 0x87, 0x6d, 0x83, 0xaa, 0x6d, 0x60, 0xb8, 0x9e);
DEFINE_GUID(FTL_PROFILE_AV1, 0xb8be4ccb, 0xcf53, 0x46ba, 0x8d, 0x59, 0xd6, 0xb8, 0xa6, 0xda, 0x5d, 0x2a);

static QStringList probeDecoders(IDXGIAdapter1 *adapter)
{
    QStringList codecs;
    ID3D11Device *device = nullptr;
    if (FAILED(D3D11CreateDevice(adapter, D3D_DRIVER_TYPE_UNKNOWN, nullptr, D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
                                 nullptr, 0, D3D11_SDK_VERSION, &device, nullptr, nullptr)))
        return codecs;
    ID3D11VideoDevice *video = nullptr;
    if (SUCCEEDED(device->QueryInterface(__uuidof(ID3D11VideoDevice), reinterpret_cast<void **>(&video)))) {
        const struct { const GUID *guid; const char *name; } profiles[] = {
            {&FTL_PROFILE_H264, "h264"}, {&FTL_PROFILE_VP9, "vp9"}, {&FTL_PROFILE_AV1, "av1"}};
        const UINT count = video->GetVideoDecoderProfileCount();
        for (const auto &p : profiles) {
            for (UINT i = 0; i < count; ++i) {
                GUID g;
                BOOL nv12 = FALSE;
                if (SUCCEEDED(video->GetVideoDecoderProfile(i, &g)) && g == *p.guid
                    && SUCCEEDED(video->CheckVideoDecoderFormat(&g, DXGI_FORMAT_NV12, &nv12)) && nv12) {
                    codecs << p.name;
                    break;
                }
            }
        }
        video->Release();
    }
    device->Release();
    return codecs;
}
#endif

QStringList Gpus::decodes(const QString &adapterName)
{
    static QHash<QString, QStringList> cache;
    if (adapterName.isEmpty())
        return {};
    if (auto it = cache.constFind(adapterName); it != cache.constEnd())
        return *it;
    QStringList codecs;
#ifdef Q_OS_WIN
    IDXGIFactory1 *factory = nullptr;
    if (SUCCEEDED(CreateDXGIFactory1(__uuidof(IDXGIFactory1), reinterpret_cast<void **>(&factory)))) {
        for (UINT i = 0;; ++i) {
            IDXGIAdapter1 *a = nullptr;
            if (FAILED(factory->EnumAdapters1(i, &a)))
                break;
            DXGI_ADAPTER_DESC1 d;
            const bool match = SUCCEEDED(a->GetDesc1(&d)) && QString::fromWCharArray(d.Description) == adapterName;
            if (match)
                codecs = probeDecoders(a);
            a->Release();
            if (match)
                break;
        }
        factory->Release();
    }
#endif
    cache.insert(adapterName, codecs);
    return codecs;
}

QString Gpus::autoFor(const QString &codec)
{
    const QString c = codec.startsWith("av01") ? "av1" : codec.startsWith("vp09") || codec.startsWith("vp9") ? "vp9"
                    : codec.startsWith("avc") ? "h264" : QString();
    if (c.isEmpty() || decodes(defaultName()).contains(c))
        return {};
    for (const QString &choice : {QStringLiteral("dedicated"), QStringLiteral("integrated")}) {
        const QString name = forChoice(choice).name;
        if (!name.isEmpty() && decodes(name).contains(c))
            return name;
    }
    return {};      // no GPU decodes it: Windows' default (decoded on the CPU)
}
