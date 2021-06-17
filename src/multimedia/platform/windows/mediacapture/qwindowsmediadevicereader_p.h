/****************************************************************************
**
** Copyright (C) 2021 The Qt Company Ltd.
** Contact: https://www.qt.io/licensing/
**
** This file is part of the Qt Mobility Components.
**
** $QT_BEGIN_LICENSE:LGPL$
** Commercial License Usage
** Licensees holding valid commercial Qt licenses may use this file in
** accordance with the commercial license agreement provided with the
** Software or, alternatively, in accordance with the terms contained in
** a written agreement between you and The Qt Company. For licensing terms
** and conditions see https://www.qt.io/terms-conditions. For further
** information use the contact form at https://www.qt.io/contact-us.
**
** GNU Lesser General Public License Usage
** Alternatively, this file may be used under the terms of the GNU Lesser
** General Public License version 3 as published by the Free Software
** Foundation and appearing in the file LICENSE.LGPL3 included in the
** packaging of this file. Please review the following information to
** ensure the GNU Lesser General Public License version 3 requirements
** will be met: https://www.gnu.org/licenses/lgpl-3.0.html.
**
** GNU General Public License Usage
** Alternatively, this file may be used under the terms of the GNU
** General Public License version 2.0 or (at your option) the GNU General
** Public license version 3 or any later version approved by the KDE Free
** Qt Foundation. The licenses are as published by the Free Software
** Foundation and appearing in the file LICENSE.GPL2 and LICENSE.GPL3
** included in the packaging of this file. Please review the following
** information to ensure the GNU General Public License requirements will
** be met: https://www.gnu.org/licenses/gpl-2.0.html and
** https://www.gnu.org/licenses/gpl-3.0.html.
**
** $QT_END_LICENSE$
**
****************************************************************************/

#ifndef QWINDOWSMEDIADEVICEREADER_H
#define QWINDOWSMEDIADEVICEREADER_H

//
//  W A R N I N G
//  -------------
//
// This file is not part of the Qt API.  It exists purely as an
// implementation detail.  This header file may change from version to
// version without notice, or even be removed.
//
// We mean it.
//

#include <mfapi.h>
#include <mfidl.h>
#include <Mferror.h>
#include <Mfreadwrite.h>

#include <QtCore/qobject.h>
#include <QtCore/qmutex.h>
#include <QtCore/qsemaphore.h>
#include <QtCore/qtimer.h>
#include <qvideoframe.h>
#include <qcameradevice.h>

QT_BEGIN_NAMESPACE

class QVideoSink;

class QWindowsMediaDeviceReader : public QObject,
        public IMFSourceReaderCallback,
        public IMFSinkWriterCallback
{
    Q_OBJECT
public:
    explicit QWindowsMediaDeviceReader(QObject *parent = nullptr);
    ~QWindowsMediaDeviceReader();

    //from IUnknown
    STDMETHODIMP QueryInterface(REFIID riid, LPVOID *ppvObject);
    STDMETHODIMP_(ULONG) AddRef(void);
    STDMETHODIMP_(ULONG) Release(void);

    //from IMFSourceReaderCallback
    STDMETHODIMP OnReadSample(HRESULT hrStatus, DWORD dwStreamIndex,
                              DWORD dwStreamFlags, LONGLONG llTimestamp, IMFSample *pSample);
    STDMETHODIMP OnFlush(DWORD dwStreamIndex);
    STDMETHODIMP OnEvent(DWORD dwStreamIndex, IMFMediaEvent *pEvent);

    //from IMFSinkWriterCallback
    STDMETHODIMP OnFinalize(HRESULT hrStatus);
    STDMETHODIMP OnMarker(DWORD dwStreamIndex, LPVOID pvContext);

    bool activate(const QString &cameraId,
                  const QCameraFormat &cameraFormat,
                  const QString &microphoneId);
    void deactivate();

    bool startRecording(const QString &fileName, const GUID &container,
                        const GUID &videoFormat, UINT32 videoBitRate, UINT32 width,
                        UINT32 height, qreal frameRate, const GUID &audioFormat,
                        UINT32 audioBitRate);
    void stopRecording();
    bool pauseRecording();
    bool resumeRecording();

    UINT32 frameWidth() const;
    UINT32 frameHeight() const;
    qreal frameRate() const;
    bool isMuted() const;
    void setMuted(bool muted);
    qreal volume() const;
    void setVolume(qreal volume);

Q_SIGNALS:
    void streamingStarted();
    void streamingStopped();
    void streamingError(int errorCode);
    void recordingStarted();
    void recordingStopped();
    void durationChanged(qint64 duration);
    void newVideoFrame(const QVideoFrame &frame);

private slots:
    void updateDuration();

private:
    HRESULT createSource(const QString &deviceId, bool video, IMFMediaSource **source);
    HRESULT createAggregateReader(IMFMediaSource *firstSource, IMFMediaSource *secondSource,
                                  IMFMediaSource **aggregateSource, IMFSourceReader **sourceReader);
    HRESULT createVideoMediaType(const GUID &format, UINT32 bitRate, UINT32 width, UINT32 height,
                                 qreal frameRate, IMFMediaType **mediaType);
    HRESULT createAudioMediaType(const GUID &format, UINT32 bitRate, IMFMediaType **mediaType);
    HRESULT prepareVideoStream(DWORD mediaTypeIndex);
    HRESULT prepareAudioStream();
    HRESULT initSourceIndexes();
    void releaseResources();
    void stopStreaming();
    DWORD findMediaTypeIndex(const QCameraFormat &reqFormat);

    long               m_cRef = 1;
    QMutex             m_mutex;
    QSemaphore         m_finalizeSemaphore;
    IMFMediaSource     *m_videoSource = nullptr;
    IMFMediaType       *m_videoMediaType = nullptr;
    IMFMediaSource     *m_audioSource = nullptr;
    IMFMediaType       *m_audioMediaType = nullptr;
    IMFMediaSource     *m_aggregateSource = nullptr;
    IMFSourceReader    *m_sourceReader = nullptr;
    IMFSinkWriter      *m_sinkWriter = nullptr;
    DWORD              m_sourceVideoStreamIndex = MF_SOURCE_READER_INVALID_STREAM_INDEX;
    DWORD              m_sourceAudioStreamIndex = MF_SOURCE_READER_INVALID_STREAM_INDEX;
    DWORD              m_sinkVideoStreamIndex = MF_SINK_WRITER_INVALID_STREAM_INDEX;
    DWORD              m_sinkAudioStreamIndex = MF_SINK_WRITER_INVALID_STREAM_INDEX;
    UINT32             m_frameWidth = 0;
    UINT32             m_frameHeight = 0;
    qreal              m_frameRate = 0.0;
    LONG               m_stride = 0;
    bool               m_active = false;
    bool               m_streaming = false;
    bool               m_recording = false;
    bool               m_firstFrame = false;
    bool               m_paused = false;
    bool               m_pauseChanging = false;
    bool               m_muted = false;
    qreal              m_volume = 1.0;
    QVideoFrameFormat::PixelFormat m_pixelFormat = QVideoFrameFormat::Format_Invalid;
    LONGLONG           m_timeOffset = 0;
    LONGLONG           m_pauseTime = 0;
    QTimer             m_durationTimer;
    qint64             m_currentDuration = -1;
    qint64             m_lastDuration = -1;
};

QT_END_NAMESPACE

#endif // QWINDOWSMEDIADEVICEREADER_H