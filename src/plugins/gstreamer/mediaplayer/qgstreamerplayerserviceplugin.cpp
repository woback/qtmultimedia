/****************************************************************************
**
** Copyright (C) 2012 Nokia Corporation and/or its subsidiary(-ies).
** Contact: http://www.qt-project.org/
**
** This file is part of the Qt Toolkit.
**
** $QT_BEGIN_LICENSE:LGPL$
** GNU Lesser General Public License Usage
** This file may be used under the terms of the GNU Lesser General Public
** License version 2.1 as published by the Free Software Foundation and
** appearing in the file LICENSE.LGPL included in the packaging of this
** file. Please review the following information to ensure the GNU Lesser
** General Public License version 2.1 requirements will be met:
** http://www.gnu.org/licenses/old-licenses/lgpl-2.1.html.
**
** In addition, as a special exception, Nokia gives you certain additional
** rights. These rights are described in the Nokia Qt LGPL Exception
** version 1.1, included in the file LGPL_EXCEPTION.txt in this package.
**
** GNU General Public License Usage
** Alternatively, this file may be used under the terms of the GNU General
** Public License version 3.0 as published by the Free Software Foundation
** and appearing in the file LICENSE.GPL included in the packaging of this
** file. Please review the following information to ensure the GNU General
** Public License version 3.0 requirements will be met:
** http://www.gnu.org/copyleft/gpl.html.
**
** Other Usage
** Alternatively, this file may be used in accordance with the terms and
** conditions contained in a signed written agreement between you and Nokia.
**
**
**
**
**
**
** $QT_END_LICENSE$
**
****************************************************************************/

#include <QtCore/qstring.h>
#include <QtCore/qdebug.h>
#include <QtCore/QDir>
#include <QtCore/QDebug>

#include "qgstreamerplayerserviceplugin.h"

//#define QT_SUPPORTEDMIMETYPES_DEBUG

#include "qgstreamerplayerservice.h"
#include <private/qgstutils_p.h>

#include <linux/types.h>
#include <sys/time.h>
#include <sys/ioctl.h>
#include <sys/poll.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <linux/videodev2.h>
#include <gst/gst.h>


QMediaService* QGstreamerPlayerServicePlugin::create(const QString &key)
{
    QGstUtils::initializeGst();

    if (key == QLatin1String(Q_MEDIASERVICE_MEDIAPLAYER))
        return new QGstreamerPlayerService;

    qWarning() << "Gstreamer service plugin: unsupported key:" << key;
    return 0;
}

void QGstreamerPlayerServicePlugin::release(QMediaService *service)
{
    delete service;
}

QMediaServiceProviderHint::Features QGstreamerPlayerServicePlugin::supportedFeatures(
        const QByteArray &service) const
{
    if (service == Q_MEDIASERVICE_MEDIAPLAYER)
        return
#ifdef HAVE_GST_APPSRC
                QMediaServiceProviderHint::StreamPlayback |
#endif
                QMediaServiceProviderHint::VideoSurface;
    else
        return QMediaServiceProviderHint::Features();
}

QtMultimedia::SupportEstimate QGstreamerPlayerServicePlugin::hasSupport(const QString &mimeType,
                                                                     const QStringList &codecs) const
{
    if (m_supportedMimeTypeSet.isEmpty())
        updateSupportedMimeTypes();

    return QGstUtils::hasSupport(mimeType, codecs, m_supportedMimeTypeSet);
}

void QGstreamerPlayerServicePlugin::updateSupportedMimeTypes() const
{
    //enumerate supported mime types
    gst_init(NULL, NULL);

    GList *plugins, *orig_plugins;
    orig_plugins = plugins = gst_default_registry_get_plugin_list ();

    while (plugins) {
        GList *features, *orig_features;

        GstPlugin *plugin = (GstPlugin *) (plugins->data);
        plugins = g_list_next (plugins);

        if (plugin->flags & (1<<1)) //GST_PLUGIN_FLAG_BLACKLISTED
            continue;

        orig_features = features = gst_registry_get_feature_list_by_plugin(gst_registry_get_default (),
                                                                        plugin->desc.name);
        while (features) {
            if (!G_UNLIKELY(features->data == NULL)) {
                GstPluginFeature *feature = GST_PLUGIN_FEATURE(features->data);
                if (GST_IS_ELEMENT_FACTORY (feature)) {
                    GstElementFactory *factory = GST_ELEMENT_FACTORY(gst_plugin_feature_load(feature));
                    if (factory
                       && factory->numpadtemplates > 0
                       && (qstrcmp(factory->details.klass, "Codec/Decoder/Audio") == 0
                          || qstrcmp(factory->details.klass, "Codec/Decoder/Video") == 0
                          || qstrcmp(factory->details.klass, "Codec/Demux") == 0 )) {
                        const GList *pads = factory->staticpadtemplates;
                        while (pads) {
                            GstStaticPadTemplate *padtemplate = (GstStaticPadTemplate*)(pads->data);
                            pads = g_list_next (pads);
                            if (padtemplate->direction != GST_PAD_SINK)
                                continue;
                            if (padtemplate->static_caps.string) {
                                GstCaps *caps = gst_static_caps_get(&padtemplate->static_caps);
                                if (!gst_caps_is_any (caps) && ! gst_caps_is_empty (caps)) {
                                    for (guint i = 0; i < gst_caps_get_size(caps); i++) {
                                        GstStructure *structure = gst_caps_get_structure(caps, i);
                                        QString nameLowcase = QString(gst_structure_get_name (structure)).toLower();

                                        m_supportedMimeTypeSet.insert(nameLowcase);
                                        if (nameLowcase.contains("mpeg")) {
                                            //Because mpeg version number is only included in the detail
                                            //description,  it is necessary to manually extract this information
                                            //in order to match the mime type of mpeg4.
                                            const GValue *value = gst_structure_get_value(structure, "mpegversion");
                                            if (value) {
                                                gchar *str = gst_value_serialize (value);
                                                QString versions(str);
                                                QStringList elements = versions.split(QRegExp("\\D+"), QString::SkipEmptyParts);
                                                foreach (const QString &e, elements)
                                                    m_supportedMimeTypeSet.insert(nameLowcase + e);
                                                g_free (str);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                        gst_object_unref (factory);
                    }
                } else if (GST_IS_TYPE_FIND_FACTORY(feature)) {
                    QString name(gst_plugin_feature_get_name(feature));
                    if (name.contains('/')) //filter out any string without '/' which is obviously not a mime type
                        m_supportedMimeTypeSet.insert(name.toLower());
                }
            }
            features = g_list_next (features);
        }
        gst_plugin_feature_list_free (orig_features);
    }
    gst_plugin_list_free (orig_plugins);

#if defined QT_SUPPORTEDMIMETYPES_DEBUG
    QStringList list = m_supportedMimeTypeSet.toList();
    list.sort();
    if (qgetenv("QT_DEBUG_PLUGINS").toInt() > 0) {
        foreach (const QString &type, list)
            qDebug() << type;
    }
#endif
}

QStringList QGstreamerPlayerServicePlugin::supportedMimeTypes() const
{
    return QStringList();
}

