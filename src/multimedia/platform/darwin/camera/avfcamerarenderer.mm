/****************************************************************************
**
** Copyright (C) 2016 The Qt Company Ltd and/or its subsidiary(-ies).
** Contact: https://www.qt.io/licensing/
**
** This file is part of the Qt Toolkit.
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

#include "private/qabstractvideobuffer_p.h"
#include "avfcamerarenderer_p.h"
#include "avfcamerasession_p.h"
#include "avfcameraservice_p.h"
#include "avfcameradebug_p.h"
#include "avfcamera_p.h"
#include <private/avfvideosink_p.h>
#include "qvideosink.h"

#import <AVFoundation/AVFoundation.h>

#ifdef Q_OS_IOS
#include <QtGui/qopengl.h>
#endif

#include <QtMultimedia/qabstractvideosurface.h>
#include <private/qabstractvideobuffer_p.h>

#include <QtMultimedia/qvideosurfaceformat.h>

QT_USE_NAMESPACE

class CVImageVideoBuffer : public QAbstractVideoBuffer
{
public:
    CVImageVideoBuffer(CVImageBufferRef buffer, AVFCameraRenderer *renderer)
#ifndef Q_OS_IOS
        : QAbstractVideoBuffer(QVideoFrame::NoHandle)
#else
        : QAbstractVideoBuffer(renderer->supportsTextures()
                               && CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA
                               ? QVideoFrame::GLTextureHandle : QVideoFrame::NoHandle)
        , m_texture(nullptr)
        , m_renderer(renderer)
#endif
        , m_buffer(buffer)
        , m_mode(QVideoFrame::NotMapped)
    {
#ifndef Q_OS_IOS
        Q_UNUSED(renderer);
#endif // Q_OS_IOS
        CVPixelBufferRetain(m_buffer);
    }

    ~CVImageVideoBuffer()
    {
        CVImageVideoBuffer::unmap();
#ifdef Q_OS_IOS
        if (m_texture)
            CFRelease(m_texture);
#endif
        CVPixelBufferRelease(m_buffer);
    }

    QVideoFrame::MapMode mapMode() const { return m_mode; }

    MapData map(QVideoFrame::MapMode mode)
    {
        MapData mapData;

        // We only support RGBA or NV12 (or Apple's version of NV12),
        // they are either 0 planes or 2.
        mapData.nPlanes = CVPixelBufferGetPlaneCount(m_buffer);
        Q_ASSERT(mapData.nPlanes <= 2);

        if (!mapData.nPlanes) {
            mapData.data[0] = map(mode, &mapData.nBytes, &mapData.bytesPerLine[0]);
            mapData.nPlanes = mapData.data[0] ? 1 : 0;
            return mapData;
        }

        // For a bi-planar format we have to set the parameters correctly:
        if (mode != QVideoFrame::NotMapped && m_mode == QVideoFrame::NotMapped) {
            CVPixelBufferLockBaseAddress(m_buffer, mode == QVideoFrame::ReadOnly
                                                               ? kCVPixelBufferLock_ReadOnly
                                                               : 0);

            mapData.nBytes = CVPixelBufferGetDataSize(m_buffer);

            // At the moment we handle only bi-planar format.
            mapData.bytesPerLine[0] = CVPixelBufferGetBytesPerRowOfPlane(m_buffer, 0);
            mapData.bytesPerLine[1] = CVPixelBufferGetBytesPerRowOfPlane(m_buffer, 1);

            mapData.data[0] = static_cast<uchar*>(CVPixelBufferGetBaseAddressOfPlane(m_buffer, 0));
            mapData.data[1] = static_cast<uchar*>(CVPixelBufferGetBaseAddressOfPlane(m_buffer, 1));

            m_mode = mode;
        }

        return mapData;
    }

    uchar *map(QVideoFrame::MapMode mode, qsizetype *numBytes, int *bytesPerLine)
    {
        if (mode != QVideoFrame::NotMapped && m_mode == QVideoFrame::NotMapped) {
            CVPixelBufferLockBaseAddress(m_buffer, mode == QVideoFrame::ReadOnly
                                                               ? kCVPixelBufferLock_ReadOnly
                                                               : 0);
            if (numBytes)
                *numBytes = CVPixelBufferGetDataSize(m_buffer);

            if (bytesPerLine)
                *bytesPerLine = CVPixelBufferGetBytesPerRow(m_buffer);

            m_mode = mode;
            return static_cast<uchar*>(CVPixelBufferGetBaseAddress(m_buffer));
        } else {
            return nullptr;
        }
    }

    void unmap()
    {
        if (m_mode != QVideoFrame::NotMapped) {
            CVPixelBufferUnlockBaseAddress(m_buffer, m_mode == QVideoFrame::ReadOnly
                                                                   ? kCVPixelBufferLock_ReadOnly
                                                                   : 0);
            m_mode = QVideoFrame::NotMapped;
        }
    }

    QVariant handle() const
    {
#ifdef Q_OS_IOS
        // Called from the render thread, so there is a current OpenGL context

        if (!m_renderer->m_textureCache) {
            CVReturn err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault,
                                                        nullptr,
                                                        [EAGLContext currentContext],
                                                        nullptr,
                                                        &m_renderer->m_textureCache);

            if (err != kCVReturnSuccess)
                qWarning("Error creating texture cache");
        }

        if (m_renderer->m_textureCache && !m_texture) {
            CVOpenGLESTextureCacheFlush(m_renderer->m_textureCache, 0);

            CVReturn err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault,
                                                                        m_renderer->m_textureCache,
                                                                        m_buffer,
                                                                        nullptr,
                                                                        GL_TEXTURE_2D,
                                                                        GL_RGBA,
                                                                        CVPixelBufferGetWidth(m_buffer),
                                                                        CVPixelBufferGetHeight(m_buffer),
                                                                        GL_RGBA,
                                                                        GL_UNSIGNED_BYTE,
                                                                        0,
                                                                        &m_texture);
            if (err != kCVReturnSuccess)
                qWarning("Error creating texture from buffer");
        }

        if (m_texture)
            return CVOpenGLESTextureGetName(m_texture);
        else
            return 0;
#else
        return QVariant();
#endif
    }

private:
#ifdef Q_OS_IOS
    mutable CVOpenGLESTextureRef m_texture;
    AVFCameraRenderer *m_renderer;
#endif
    CVImageBufferRef m_buffer;
    QVideoFrame::MapMode m_mode;
};


@interface AVFCaptureFramesDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>

- (AVFCaptureFramesDelegate *) initWithRenderer:(AVFCameraRenderer*)renderer;

- (void) captureOutput:(AVCaptureOutput *)captureOutput
         didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
         fromConnection:(AVCaptureConnection *)connection;

@end

@implementation AVFCaptureFramesDelegate
{
@private
    AVFCameraRenderer *m_renderer;
}

- (AVFCaptureFramesDelegate *) initWithRenderer:(AVFCameraRenderer*)renderer
{
    if (!(self = [super init]))
        return nil;

    self->m_renderer = renderer;
    return self;
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput
         didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
         fromConnection:(AVCaptureConnection *)connection
{
    Q_UNUSED(connection);
    Q_UNUSED(captureOutput);

    // NB: on iOS captureOutput/connection can be nil (when recording a video -
    // avfmediaassetwriter).

    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);

    int width = CVPixelBufferGetWidth(imageBuffer);
    int height = CVPixelBufferGetHeight(imageBuffer);
    QVideoSurfaceFormat::PixelFormat format =
            AVFCamera::QtPixelFormatFromCVFormat(CVPixelBufferGetPixelFormatType(imageBuffer));
    if (format == QVideoSurfaceFormat::Format_Invalid)
avfcamerarenderercontrol.mm
        return;

    QVideoFrame frame(new CVImageVideoBuffer(imageBuffer, m_renderer),
                      QSize(width, height),
                      format);

    m_renderer->syncHandleViewfinderFrame(frame);
}

@end


AVFCameraRenderer::AVFCameraRenderer(QObject *parent)
   : QObject(parent)
{
    m_viewfinderFramesDelegate = [[AVFCaptureFramesDelegate alloc] initWithRenderer:this];
}

AVFCameraRenderer::~AVFCameraRenderer()
{
    [m_cameraSession->captureSession() removeOutput:m_videoDataOutput];
    [m_viewfinderFramesDelegate release];
    if (m_delegateQueue)
        dispatch_release(m_delegateQueue);
#ifdef Q_OS_IOS
    if (m_textureCache)
        CFRelease(m_textureCache);
#endif
}

void AVFCameraRenderer::reconfigure()
{
    QMutexLocker lock(&m_vfMutex);

    renderToNativeView(shouldRenderToWindow());

    m_rendersToWindow = rendersToWindow();

    updateAspectRatio();
    // ### This is a hack, need to use a reliable way to determine the size and not use the preview layer
    if (m_layer)
        m_sink->setNativeSize(QSize(m_layer.bounds.size.width, m_layer.bounds.size.height));
    nativeSizeChanged();
}

void AVFCameraRenderer::configureAVCaptureSession(AVFCameraSession *cameraSession)
{
    m_cameraSession = cameraSession;
    connect(m_cameraSession, SIGNAL(readyToConfigureConnections()),
            this, SLOT(updateCaptureConnection()));

    m_needsHorizontalMirroring = false;

    m_videoDataOutput = [[[AVCaptureVideoDataOutput alloc] init] autorelease];

    // Configure video output
    m_delegateQueue = dispatch_queue_create("vf_queue", nullptr);
    [m_videoDataOutput
            setSampleBufferDelegate:m_viewfinderFramesDelegate
            queue:m_delegateQueue];

    [m_cameraSession->captureSession() addOutput:m_videoDataOutput];
}

void AVFCameraRenderer::updateCaptureConnection()
{
    AVCaptureConnection *connection = [m_videoDataOutput connectionWithMediaType:AVMediaTypeVideo];
    if (connection == nil || !m_cameraSession->videoCaptureDevice())
        return;

    // Frames of front-facing cameras should be mirrored horizontally (it's the default when using
    // AVCaptureVideoPreviewLayer but not with AVCaptureVideoDataOutput)
    if (connection.isVideoMirroringSupported)
        connection.videoMirrored = m_cameraSession->videoCaptureDevice().position == AVCaptureDevicePositionFront;

    // If the connection does't support mirroring, we'll have to do it ourselves
    m_needsHorizontalMirroring = !connection.isVideoMirrored
            && m_cameraSession->videoCaptureDevice().position == AVCaptureDevicePositionFront;
}

//can be called from non main thread
void AVFCameraRenderer::syncHandleViewfinderFrame(const QVideoFrame &frame)
{
    QMutexLocker lock(&m_vfMutex);
    if (m_rendersToWindow)
        return;

    if (!m_lastViewfinderFrame.isValid()) {
        static QMetaMethod handleViewfinderFrameSlot = metaObject()->method(
                    metaObject()->indexOfMethod("handleViewfinderFrame()"));

        handleViewfinderFrameSlot.invoke(this, Qt::QueuedConnection);
    }

    m_lastViewfinderFrame = frame;
}

AVCaptureVideoDataOutput *AVFCameraRenderer::videoDataOutput() const
{
    return m_videoDataOutput;
}

AVFCaptureFramesDelegate *AVFCameraRenderer::captureDelegate() const
{
    return m_viewfinderFramesDelegate;
}

void AVFCameraRenderer::resetCaptureDelegate() const
{
    [m_videoDataOutput setSampleBufferDelegate:m_viewfinderFramesDelegate queue:m_delegateQueue];
}

void AVFCameraRenderer::handleViewfinderFrame()
{
    QVideoFrame frame;
    {
        QMutexLocker lock(&m_vfMutex);
        frame = m_lastViewfinderFrame;
        m_lastViewfinderFrame = QVideoFrame();
    }

    if (m_sink && frame.isValid()) {
        // ### pass format to surface
        QVideoSurfaceFormat format(frame.size(), frame.pixelFormat(), frame.handleType());
        if (m_needsHorizontalMirroring)
            format.setMirrored(true);

        m_sink->videoSink()->newVideoFrame(frame);
    }
}


void AVFCameraRenderer::updateAspectRatio()
{
    if (!m_layer)
        return;

    AVLayerVideoGravity gravity = AVLayerVideoGravityResizeAspect;

    switch (aspectRatioMode()) {
    case Qt::IgnoreAspectRatio:
        gravity = AVLayerVideoGravityResize;
        break;
    case Qt::KeepAspectRatio:
        gravity = AVLayerVideoGravityResizeAspect;
        break;
    case Qt::KeepAspectRatioByExpanding:
        gravity = AVLayerVideoGravityResizeAspectFill;
        break;
    default:
        break;
    }
    auto *layer = static_cast<AVCaptureVideoPreviewLayer *>(m_layer);
    layer.videoGravity = gravity;
}

#include "moc_avfcamerarenderer_p.cpp"