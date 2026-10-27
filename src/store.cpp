#include "store.h"
#include "paths.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJSValue>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QRegularExpression>
#include <QSaveFile>
#include <QSet>

namespace {
QString fileFor(const QString &name)
{
    static const QRegularExpression valid("^[A-Za-z0-9-]+$");
    return valid.match(name).hasMatch() ? Paths::data() + "/" + name + ".json" : QString();
}

QVariant plain(const QVariant &v)
{
    // JavaScript arrays arrive wrapped as QJSValue; unwrap them so they serialise as JSON arrays.
    return v.canConvert<QJSValue>() ? v.value<QJSValue>().toVariant() : v;
}

const QRegularExpression channelIdRe("(UC[A-Za-z0-9_-]{22})");

QString xmlUnescape(QString s)
{
    s.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&apos;", "'").replace("&#39;", "'");
    return s.replace("&amp;", "&");
}

QString xmlEscape(QString s)
{
    return s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;");
}

QString csvField(QString s)
{
    return s.contains(',') || s.contains('"') ? '"' + s.replace('"', "\"\"") + '"' : s;
}

// Splits one CSV line, honouring quoted fields.
QStringList csvSplit(const QString &line)
{
    QStringList fields;
    QString cur;
    bool quoted = false;
    for (qsizetype i = 0; i < line.size(); ++i) {
        const QChar c = line.at(i);
        if (quoted) {
            if (c == '"' && i + 1 < line.size() && line.at(i + 1) == '"') { cur += '"'; ++i; }
            else if (c == '"') quoted = false;
            else cur += c;
        } else if (c == '"') {
            quoted = true;
        } else if (c == ',') {
            fields << cur;
            cur.clear();
        } else {
            cur += c;
        }
    }
    fields << cur;
    return fields;
}
} // namespace

QVariant Store::load(const QString &name, const QVariant &fallback) const
{
    QFile f(fileFor(name));
    if (f.fileName().isEmpty() || !f.open(QIODevice::ReadOnly))
        return fallback;
    QJsonParseError err;
    const QJsonDocument doc = QJsonDocument::fromJson(f.readAll(), &err);
    return err.error == QJsonParseError::NoError ? doc.toVariant() : fallback;
}

bool Store::save(const QString &name, const QVariant &value) const
{
    const QString path = fileFor(name);
    if (path.isEmpty())
        return false;
    QDir().mkpath(Paths::data());
    QSaveFile f(path); // written to a temporary file and renamed, so a crash never leaves half a file
    if (!f.open(QIODevice::WriteOnly))
        return false;
    f.write(QJsonDocument::fromVariant(plain(value)).toJson(QJsonDocument::Compact));
    return f.commit();
}

QVariantMap Store::importSubscriptions(const QUrl &file) const
{
    QFile f(file.toLocalFile());
    if (!f.open(QIODevice::ReadOnly))
        return {{"error", "Could not open the file."}};
    const QByteArray data = f.readAll();
    const QString text = QString::fromUtf8(data).trimmed();

    QVariantList channels;
    QSet<QString> seen;
    auto add = [&](const QString &id, const QString &name, const QString &thumb = {}) {
        if (id.isEmpty() || seen.contains(id))
            return;
        seen.insert(id);
        channels.append(QVariantMap{{"id", id}, {"name", name.isEmpty() ? id : name}, {"thumbnail", thumb}});
    };
    auto idFrom = [](const QString &s) { return channelIdRe.match(s).captured(1); };
    QString format;

    const QJsonDocument whole = QJsonDocument::fromJson(data);
    if (whole.isObject() && whole.object().value("subscriptions").isArray()
        && whole.object().contains("app_version")) {
        // NewPipe: {"app_version": ..., "subscriptions": [{"service_id": 0, "url": ".../channel/UC...", "name": ...}]}
        format = "NewPipe";
        for (const QJsonValue &v : whole.object().value("subscriptions").toArray()) {
            const QJsonObject o = v.toObject();
            if (o.value("service_id").toInt(0) == 0)
                add(idFrom(o.value("url").toString()), o.value("name").toString());
        }
    } else if (whole.isArray()) {
        // Older FreeTube JSON exports: [{"channelId"/"id", "channelName"/"name", "channelThumbnail"/"thumbnail"}]
        format = "FreeTube (JSON)";
        for (const QJsonValue &v : whole.array()) {
            const QJsonObject o = v.toObject();
            add(idFrom(o.value(o.contains("channelId") ? "channelId" : "id").toString()),
                o.value(o.contains("channelName") ? "channelName" : "name").toString(),
                o.value(o.contains("channelThumbnail") ? "channelThumbnail" : "thumbnail").toString());
        }
    } else if (text.startsWith('{')) {
        // FreeTube (.db, NeDB): one profile document per line, later lines replace earlier ones. Channels of
        // all profiles are imported (each profile's channels are also in "All Channels").
        format = "FreeTube";
        QMap<QString, QJsonObject> profiles;
        for (const QString &line : text.split('\n')) {
            const QJsonObject o = QJsonDocument::fromJson(line.trimmed().toUtf8()).object();
            if (o.isEmpty())
                continue;
            const QString id = o.value("_id").toString();
            if (o.contains("$$deleted")) profiles.remove(id);
            else profiles.insert(id, o);
        }
        for (const QJsonObject &p : profiles)
            for (const QJsonValue &v : p.value("subscriptions").toArray()) {
                const QJsonObject c = v.toObject();
                add(idFrom(c.value("id").toString()), c.value("name").toString(), c.value("thumbnail").toString());
            }
    } else if (text.startsWith('<')) {
        // OPML: <outline text="Name" title="Name" type="rss" xmlUrl="...feeds/videos.xml?channel_id=UC..."/>
        format = "OPML";
        static const QRegularExpression outline("<outline\\b[^>]*>");
        static const QRegularExpression titleRe("\\b(?:title|text)=\"([^\"]*)\"");
        for (auto it = outline.globalMatch(text); it.hasNext();) {
            const QString tag = it.next().captured(0);
            add(idFrom(tag), xmlUnescape(titleRe.match(tag).captured(1)));
        }
    } else {
        // YouTube Takeout CSV: "Channel Id,Channel Url,Channel Title". The header is localised, so the channel
        // id is recognised by its shape rather than by column name.
        format = "YouTube (CSV)";
        for (const QString &line : text.split('\n')) {
            const QStringList fields = csvSplit(line.trimmed());
            const QString id = fields.isEmpty() ? QString() : idFrom(fields.first());
            if (!id.isEmpty())
                add(id, fields.size() >= 3 ? fields.at(2).trimmed() : fields.value(1));
        }
    }
    if (channels.isEmpty())
        return {{"error", "No YouTube channels were found in this file."}, {"format", format}};
    return {{"channels", channels}, {"format", format}};
}

QString Store::exportSubscriptions(const QUrl &file, const QVariant &channels) const
{
    const QVariantList list = plain(channels).toList();
    const QString path = file.toLocalFile();
    const QString ext = QFileInfo(path).suffix().toLower();
    QByteArray out;
    if (ext == "db") {
        QJsonArray subs;
        for (const QVariant &c : list) {
            const QVariantMap m = c.toMap();
            subs.append(QJsonObject{{"id", m.value("id").toString()}, {"name", m.value("name").toString()},
                                    {"thumbnail", m.value("thumbnail").toString()}});
        }
        const QJsonObject profile{{"_id", "allChannels"}, {"name", "All Channels"}, {"bgColor", "#000000"},
                                  {"textColor", "#FFFFFF"}, {"subscriptions", subs}};
        out = QJsonDocument(profile).toJson(QJsonDocument::Compact) + '\n';
    } else if (ext == "csv") {
        out = "Channel Id,Channel Url,Channel Title\n";
        for (const QVariant &c : list) {
            const QVariantMap m = c.toMap();
            const QString id = m.value("id").toString();
            out += (id + ",http://www.youtube.com/channel/" + id + "," + csvField(m.value("name").toString()) + "\n").toUtf8();
        }
    } else if (ext == "json") {
        QJsonArray subs;
        for (const QVariant &c : list) {
            const QVariantMap m = c.toMap();
            subs.append(QJsonObject{{"service_id", 0},
                                    {"url", "https://www.youtube.com/channel/" + m.value("id").toString()},
                                    {"name", m.value("name").toString()}});
        }
        out = QJsonDocument(QJsonObject{{"app_version", "0.27.0"}, {"app_version_int", 1000}, {"subscriptions", subs}})
                  .toJson(QJsonDocument::Indented);
    } else if (ext == "opml" || ext == "xml") {
        out = "<opml version=\"1.1\"><body><outline text=\"YouTube Subscriptions\" title=\"YouTube Subscriptions\">\n";
        for (const QVariant &c : list) {
            const QVariantMap m = c.toMap();
            const QString name = xmlEscape(m.value("name").toString());
            out += ("<outline text=\"" + name + "\" title=\"" + name + "\" type=\"rss\" xmlUrl=\""
                    "https://www.youtube.com/feeds/videos.xml?channel_id=" + m.value("id").toString() + "\"/>\n").toUtf8();
        }
        out += "</outline></body></opml>\n";
    } else {
        return "Choose a .db, .csv, .opml or .json file name.";
    }
    QSaveFile f(path);
    if (!f.open(QIODevice::WriteOnly))
        return "Could not write the file.";
    f.write(out);
    return f.commit() ? QString() : "Could not write the file.";
}
