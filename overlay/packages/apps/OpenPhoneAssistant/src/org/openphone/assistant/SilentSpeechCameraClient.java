package org.openphone.assistant;

import android.content.Context;
import android.graphics.Matrix;
import android.graphics.SurfaceTexture;
import android.hardware.camera2.CameraAccessException;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraDevice;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CaptureRequest;
import android.hardware.camera2.CaptureResult;
import android.hardware.camera2.TotalCaptureResult;
import android.hardware.camera2.params.StreamConfigurationMap;
import android.media.MediaRecorder;
import android.os.Handler;
import android.os.HandlerThread;
import android.util.Log;
import android.util.Size;
import android.view.Surface;
import android.view.TextureView;

import java.io.File;
import java.io.IOException;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Authenticated Silent Speech capture path for AI Home.
 *
 * <p>The front camera records an H.264 MP4. On release, the video is uploaded
 * through the user's Interfaces Firebase session, allowing the API to derive
 * the active personal model from the authenticated UID.</p>
 */
final class SilentSpeechCameraClient implements AutoCloseable {
    interface Listener {
        void onCaptureStarting();
        void onCaptureStarted();
        void onFrameCaptured(int count);
        void onDecoding(int frameCount);
        void onDecoded(String text);
        void onError(String message);
        void onCancelled();
    }

    private static final String TAG = "OpenPhoneSilentSpeech";
    private static final int MIN_FRAMES = 8;
    private static final int MAX_FRAMES = 450;
    private static final long MIN_FRAME_INTERVAL_NS = 33_000_000L;

    private final Context mContext;
    private final InterfacesAuthClient mAuthClient;
    private final Listener mListener;
    private final Handler mMainHandler;
    private final ExecutorService mDecodeExecutor = Executors.newSingleThreadExecutor();

    private volatile boolean mBusy;
    private volatile boolean mRecording;
    private volatile boolean mClosed;
    private HandlerThread mCameraThread;
    private Handler mCameraHandler;
    private CameraDevice mCamera;
    private CameraCaptureSession mSession;
    private MediaRecorder mRecorder;
    private Surface mRecorderSurface;
    private File mOutputFile;
    private TextureView mPreviewView;
    private SurfaceTexture mPreviewTexture;
    private Surface mPreviewSurface;
    private Size mCaptureSize;
    private boolean mSessionCreating;
    private boolean mCameraOpening;
    private boolean mRecorderStarted;
    private int mGraphGeneration;
    private long mLastFrameTimestampNs;
    private long mHoldStartedAtMillis;
    private long mRecorderStartedAtMillis;
    private int mFrameCount;
    private int mSensorOrientation;

    SilentSpeechCameraClient(
            Context context, InterfacesAuthClient authClient, Listener listener) {
        mContext = context.getApplicationContext();
        mAuthClient = authClient;
        mListener = listener;
        mMainHandler = new Handler(context.getMainLooper());
    }

    boolean isRecording() {
        return mRecording;
    }

    boolean isBusy() {
        return mBusy;
    }

    /** Opens and configures the front camera without recording user data. */
    void prepare() {
        if (mClosed) {
            return;
        }
        ensureCameraThread();
        Handler handler = mCameraHandler;
        if (handler == null) {
            return;
        }
        handler.post(new Runnable() {
            @Override
            public void run() {
                if (mClosed) {
                    return;
                }
                if (mSession != null) {
                    return;
                }
                if (mCamera != null) {
                    maybeCreateCaptureSession();
                    return;
                }
                openFrontCamera();
            }
        });
    }

    void attachPreview(TextureView previewView) {
        mPreviewView = previewView;
        previewView.setSurfaceTextureListener(new TextureView.SurfaceTextureListener() {
            @Override
            public void onSurfaceTextureAvailable(SurfaceTexture surface, int width, int height) {
                preparePreviewSurface(surface);
            }

            @Override
            public void onSurfaceTextureSizeChanged(
                    SurfaceTexture surface, int width, int height) {
                configurePreviewTransform(previewView);
            }

            @Override
            public boolean onSurfaceTextureDestroyed(SurfaceTexture surface) {
                releasePreviewSurface();
                return true;
            }

            @Override
            public void onSurfaceTextureUpdated(SurfaceTexture surface) {
            }
        });
        if (previewView.isAvailable()) {
            preparePreviewSurface(previewView.getSurfaceTexture());
        }
        configurePreviewTransform(previewView);
    }

    void detachPreview(TextureView previewView) {
        if (mPreviewView != previewView) {
            return;
        }
        previewView.setSurfaceTextureListener(null);
        mPreviewView = null;
        if (!mRecording) {
            releasePreviewSurface();
        }
    }

    void start() {
        if (mBusy || mClosed) {
            return;
        }
        mBusy = true;
        mRecording = true;
        mHoldStartedAtMillis = System.currentTimeMillis();
        mFrameCount = 0;
        mLastFrameTimestampNs = 0L;
        mRecorderStarted = false;
        postMain(new Runnable() {
            @Override
            public void run() {
                mListener.onCaptureStarting();
            }
        });

        ensureCameraThread();
        Handler handler = mCameraHandler;
        if (handler == null) {
            fail("The front camera could not start.");
            return;
        }
        handler.post(new Runnable() {
            @Override
            public void run() {
                if (mSession != null) {
                    beginRecording();
                } else if (mCamera != null) {
                    maybeCreateCaptureSession();
                } else {
                    openFrontCamera();
                }
            }
        });
    }

    private void ensureCameraThread() {
        if (mCameraThread != null && mCameraHandler != null) {
            return;
        }
        mCameraThread = new HandlerThread("OpenPhoneSilentSpeechCamera");
        mCameraThread.start();
        mCameraHandler = new Handler(mCameraThread.getLooper());
    }

    void stopAndDecode() {
        if (!mRecording || mCameraHandler == null) {
            return;
        }
        mCameraHandler.post(new Runnable() {
            @Override
            public void run() {
                finishCapture(true);
            }
        });
    }

    void cancel() {
        if (!mBusy) {
            return;
        }
        mRecording = false;
        Handler handler = mCameraHandler;
        if (handler != null) {
            handler.post(new Runnable() {
                @Override
                public void run() {
                    closeCameraGraph();
                    mBusy = false;
                    prepare();
                    postMain(new Runnable() {
                        @Override
                        public void run() {
                            mListener.onCancelled();
                        }
                    });
                }
            });
        } else {
            mBusy = false;
            postMain(new Runnable() {
                @Override
                public void run() {
                    mListener.onCancelled();
                }
            });
        }
    }

    private void openFrontCamera() {
        if (mClosed || mCameraOpening || mCamera != null) {
            return;
        }
        mCameraOpening = true;
        final int graphGeneration = mGraphGeneration;
        try {
            CameraManager manager = (CameraManager) mContext.getSystemService(Context.CAMERA_SERVICE);
            String cameraId = frontCameraId(manager);
            CameraCharacteristics characteristics = manager.getCameraCharacteristics(cameraId);
            Integer orientation = characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION);
            mSensorOrientation = orientation == null ? 0 : orientation;
            Size size = captureSize(characteristics);
            mCaptureSize = size;
            prepareRecorder(size);
            configurePreviewTransform(mPreviewView);
            TextureView preview = mPreviewView;
            if (preview != null && preview.isAvailable()) {
                preparePreviewSurface(preview.getSurfaceTexture());
            }
            manager.openCamera(cameraId, new CameraDevice.StateCallback() {
                @Override
                public void onOpened(CameraDevice camera) {
                    mCameraOpening = false;
                    if (mClosed || graphGeneration != mGraphGeneration) {
                        camera.close();
                        return;
                    }
                    mCamera = camera;
                    maybeCreateCaptureSession();
                }

                @Override
                public void onDisconnected(CameraDevice camera) {
                    mCameraOpening = false;
                    camera.close();
                    fail("The front camera disconnected.");
                }

                @Override
                public void onError(CameraDevice camera, int error) {
                    mCameraOpening = false;
                    camera.close();
                    fail("The front camera could not start (" + error + ").");
                }
            }, mCameraHandler);
        } catch (SecurityException e) {
            mCameraOpening = false;
            fail("Camera permission is required for Silent Speech.");
        } catch (CameraAccessException | IOException | IllegalStateException e) {
            mCameraOpening = false;
            Log.e(TAG, "Unable to open front camera", e);
            fail("The front camera could not start.");
        }
    }

    private void preparePreviewSurface(SurfaceTexture texture) {
        Handler handler = mCameraHandler;
        if (handler == null || texture == null) {
            return;
        }
        handler.post(new Runnable() {
            @Override
            public void run() {
                if (!mRecording || mCaptureSize == null) {
                    return;
                }
                if (mPreviewTexture == texture && mPreviewSurface != null) {
                    maybeCreateCaptureSession();
                    return;
                }
                if (mSessionCreating || mSession != null) {
                    return;
                }
                releasePreviewSurface();
                texture.setDefaultBufferSize(
                        mCaptureSize.getWidth(), mCaptureSize.getHeight());
                mPreviewTexture = texture;
                mPreviewSurface = new Surface(texture);
                configurePreviewTransform(mPreviewView);
                maybeCreateCaptureSession();
            }
        });
    }

    private void maybeCreateCaptureSession() {
        if (mSessionCreating || mSession != null || mCamera == null
                || mRecorder == null || mRecorderSurface == null || mPreviewSurface == null) {
            return;
        }
        mSessionCreating = true;
        final CameraDevice camera = mCamera;
        final Surface previewSurface = mPreviewSurface;
        final Surface recorderSurface = mRecorderSurface;
        try {
            camera.createCaptureSession(
                    java.util.Arrays.asList(previewSurface, recorderSurface),
                    new CameraCaptureSession.StateCallback() {
                        @Override
                        public void onConfigured(CameraCaptureSession session) {
                            mSessionCreating = false;
                            if (mClosed || mCamera != camera || mRecorder == null
                                    || mPreviewSurface != previewSurface
                                    || mRecorderSurface != recorderSurface) {
                                session.close();
                                maybeCreateCaptureSession();
                                return;
                            }
                            mSession = session;
                            try {
                                CaptureRequest.Builder request = camera.createCaptureRequest(
                                        CameraDevice.TEMPLATE_PREVIEW);
                                request.addTarget(previewSurface);
                                request.set(CaptureRequest.CONTROL_MODE,
                                        CaptureRequest.CONTROL_MODE_AUTO);
                                request.set(CaptureRequest.CONTROL_AF_MODE,
                                        CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO);
                                session.setRepeatingRequest(request.build(), null, mCameraHandler);
                                if (mRecording) {
                                    beginRecording();
                                }
                            } catch (CameraAccessException | RuntimeException e) {
                                Log.e(TAG, "Unable to start camera capture", e);
                                fail("The front camera could not begin recording.");
                            }
                        }

                        @Override
                        public void onConfigureFailed(CameraCaptureSession session) {
                            mSessionCreating = false;
                            fail("The front camera could not be configured.");
                        }
                    },
                    mCameraHandler);
        } catch (CameraAccessException | IllegalStateException e) {
            mSessionCreating = false;
            Log.e(TAG, "Unable to create camera session", e);
            fail("The front camera could not be configured.");
        }
    }

    private void beginRecording() {
        if (!mRecording || mRecorderStarted || mSession == null || mCamera == null
                || mPreviewSurface == null || mRecorderSurface == null || mRecorder == null) {
            return;
        }
        try {
            CaptureRequest.Builder request = mCamera.createCaptureRequest(
                    CameraDevice.TEMPLATE_RECORD);
            request.addTarget(mPreviewSurface);
            request.addTarget(mRecorderSurface);
            request.set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_AUTO);
            request.set(CaptureRequest.CONTROL_AF_MODE,
                    CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO);
            mSession.setRepeatingRequest(
                    request.build(),
                    new CameraCaptureSession.CaptureCallback() {
                        @Override
                        public void onCaptureCompleted(
                                CameraCaptureSession captureSession,
                                CaptureRequest captureRequest,
                                TotalCaptureResult result) {
                            onCameraFrame(result);
                        }
                    },
                    mCameraHandler);
            mRecorder.start();
            mRecorderStarted = true;
            mRecorderStartedAtMillis = System.currentTimeMillis();
            Log.i(TAG, "recording started startup_ms="
                    + (mRecorderStartedAtMillis - mHoldStartedAtMillis));
            postMain(new Runnable() {
                @Override
                public void run() {
                    mListener.onCaptureStarted();
                }
            });
        } catch (CameraAccessException | RuntimeException e) {
            Log.e(TAG, "Unable to start camera capture", e);
            fail("The front camera could not begin recording.");
        }
    }

    private void onCameraFrame(TotalCaptureResult result) {
        if (!mRecording || !mRecorderStarted) {
            return;
        }
        Long sensorTimestamp = result.get(CaptureResult.SENSOR_TIMESTAMP);
        long timestamp = sensorTimestamp == null ? System.nanoTime() : sensorTimestamp;
        if (mLastFrameTimestampNs != 0L
                && timestamp - mLastFrameTimestampNs < MIN_FRAME_INTERVAL_NS) {
            return;
        }
        mLastFrameTimestampNs = timestamp;
        int count = ++mFrameCount;
        postMain(new Runnable() {
            @Override
            public void run() {
                mListener.onFrameCaptured(count);
            }
        });
        if (count >= MAX_FRAMES) {
            finishCapture(true);
        }
    }

    private void finishCapture(boolean decode) {
        if (!mRecording) {
            return;
        }
        mRecording = false;
        stopRepeating();
        File captured = finishRecorder();
        int capturedFrames = mFrameCount;
        long now = System.currentTimeMillis();
        Log.i(TAG, "recording stopped hold_ms=" + (now - mHoldStartedAtMillis)
                + " recorded_ms=" + (mRecorderStartedAtMillis == 0L
                ? 0L : now - mRecorderStartedAtMillis)
                + " frames=" + capturedFrames);
        closeCameraGraph();
        prepare();
        if (!decode) {
            mBusy = false;
            delete(captured);
            return;
        }
        if (capturedFrames < MIN_FRAMES || captured == null || captured.length() == 0L) {
            mBusy = false;
            delete(captured);
            postError("Hold still and mouth your request a little longer.");
            return;
        }
        postMain(new Runnable() {
            @Override
            public void run() {
                mListener.onDecoding(capturedFrames);
            }
        });
        mDecodeExecutor.execute(new Runnable() {
            @Override
            public void run() {
                upload(captured);
            }
        });
    }

    private void upload(File video) {
        try {
            String text = mAuthClient.decodeSilentSpeech(video);
            mBusy = false;
            postMain(new Runnable() {
                @Override
                public void run() {
                    mListener.onDecoded(text);
                }
            });
        } catch (Exception e) {
            Log.e(TAG, "Silent Speech decode failed", e);
            String message = e.getMessage();
            if (message == null || message.trim().isEmpty()) {
                message = "Silent Speech could not decode this take.";
            }
            finishUploadWithError(message);
        } finally {
            delete(video);
        }
    }

    private void finishUploadWithError(String message) {
        mBusy = false;
        postError(message);
    }

    private void fail(String message) {
        mRecording = false;
        mBusy = false;
        closeCameraGraph();
        postError(message);
    }

    private void postError(String message) {
        final String clean = message == null || message.trim().isEmpty()
                ? "Silent Speech could not complete this take." : message.trim();
        postMain(new Runnable() {
            @Override
            public void run() {
                mListener.onError(clean);
            }
        });
    }

    private void closeCameraGraph() {
        mGraphGeneration++;
        mCameraOpening = false;
        CameraCaptureSession session = mSession;
        mSession = null;
        if (session != null) {
            try {
                session.stopRepeating();
                session.abortCaptures();
            } catch (CameraAccessException | IllegalStateException ignored) {
            }
            session.close();
        }
        CameraDevice camera = mCamera;
        mCamera = null;
        if (camera != null) {
            camera.close();
        }
        releaseRecorder(true);
        releasePreviewSurface();
        mCaptureSize = null;
        mSessionCreating = false;
        mRecorderStartedAtMillis = 0L;
        HandlerThread thread = mCameraThread;
        mCameraThread = null;
        mCameraHandler = null;
        if (thread != null) {
            thread.quitSafely();
        }
    }

    private static String frontCameraId(CameraManager manager) throws CameraAccessException {
        for (String id : manager.getCameraIdList()) {
            Integer facing = manager.getCameraCharacteristics(id)
                    .get(CameraCharacteristics.LENS_FACING);
            if (facing != null && facing == CameraCharacteristics.LENS_FACING_FRONT) {
                return id;
            }
        }
        throw new CameraAccessException(CameraAccessException.CAMERA_ERROR,
                "No front camera is available");
    }

    private static Size captureSize(CameraCharacteristics characteristics) {
        StreamConfigurationMap map = characteristics.get(
                CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP);
        if (map == null || map.getOutputSizes(MediaRecorder.class) == null) {
            return new Size(640, 480);
        }
        ArrayList<Size> candidates = new ArrayList<>();
        Collections.addAll(candidates, map.getOutputSizes(MediaRecorder.class));
        if (candidates.isEmpty()) {
            return new Size(640, 480);
        }
        candidates.sort(Comparator.comparingLong(
                size -> (long) size.getWidth() * (long) size.getHeight()));
        for (Size size : candidates) {
            int shortSide = Math.min(size.getWidth(), size.getHeight());
            int longSide = Math.max(size.getWidth(), size.getHeight());
            if (shortSide >= 480 && longSide >= 640 && longSide <= 1280) {
                return size;
            }
        }
        return candidates.get(0);
    }

    private void prepareRecorder(Size size) throws IOException {
        File output = new File(
                mContext.getCacheDir(), "silent-speech-" + UUID.randomUUID() + ".mp4");
        MediaRecorder recorder = new MediaRecorder(mContext);
        recorder.setVideoSource(MediaRecorder.VideoSource.SURFACE);
        recorder.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4);
        recorder.setOutputFile(output.getAbsolutePath());
        recorder.setVideoEncodingBitRate(2_500_000);
        recorder.setVideoFrameRate(30);
        recorder.setVideoSize(size.getWidth(), size.getHeight());
        recorder.setVideoEncoder(MediaRecorder.VideoEncoder.H264);
        recorder.setOrientationHint(mSensorOrientation);
        recorder.prepare();
        mRecorder = recorder;
        mRecorderSurface = recorder.getSurface();
        mOutputFile = output;
    }

    private void stopRepeating() {
        CameraCaptureSession session = mSession;
        if (session == null) {
            return;
        }
        try {
            session.stopRepeating();
            session.abortCaptures();
        } catch (CameraAccessException | IllegalStateException ignored) {
        }
    }

    private File finishRecorder() {
        MediaRecorder recorder = mRecorder;
        File output = mOutputFile;
        if (recorder == null || !mRecorderStarted) {
            releaseRecorder(true);
            return null;
        }
        try {
            recorder.stop();
        } catch (RuntimeException error) {
            Log.w(TAG, "Unable to finish Silent Speech video", error);
            delete(output);
            output = null;
        }
        releaseRecorder(false);
        return output;
    }

    private void releaseRecorder(boolean deleteOutput) {
        MediaRecorder recorder = mRecorder;
        mRecorder = null;
        mRecorderStarted = false;
        if (recorder != null) {
            try {
                recorder.reset();
            } catch (RuntimeException ignored) {
            }
            recorder.release();
        }
        Surface surface = mRecorderSurface;
        mRecorderSurface = null;
        if (surface != null) {
            surface.release();
        }
        File output = mOutputFile;
        mOutputFile = null;
        if (deleteOutput) {
            delete(output);
        }
    }

    private static void delete(File file) {
        if (file != null && file.exists() && !file.delete()) {
            Log.w(TAG, "Unable to delete temporary Silent Speech video");
        }
    }

    private void releasePreviewSurface() {
        Surface surface = mPreviewSurface;
        mPreviewSurface = null;
        mPreviewTexture = null;
        if (surface != null) {
            surface.release();
        }
    }

    private void configurePreviewTransform(TextureView previewView) {
        final Size captureSize = mCaptureSize;
        final int sensorOrientation = mSensorOrientation;
        if (previewView == null || captureSize == null) {
            return;
        }
        previewView.post(new Runnable() {
            @Override
            public void run() {
                if (previewView != mPreviewView
                        || previewView.getWidth() <= 0 || previewView.getHeight() <= 0) {
                    return;
                }
                float bufferWidth = captureSize.getWidth();
                float bufferHeight = captureSize.getHeight();
                if (sensorOrientation % 180 != 0) {
                    float swap = bufferWidth;
                    bufferWidth = bufferHeight;
                    bufferHeight = swap;
                }
                float viewWidth = previewView.getWidth();
                float viewHeight = previewView.getHeight();
                float bufferAspect = bufferWidth / bufferHeight;
                float viewAspect = viewWidth / viewHeight;
                float scaleX = 1f;
                float scaleY = 1f;
                if (bufferAspect > viewAspect) {
                    scaleX = bufferAspect / viewAspect;
                } else {
                    scaleY = viewAspect / bufferAspect;
                }
                Matrix transform = new Matrix();
                float centerX = viewWidth / 2f;
                float centerY = viewHeight / 2f;
                transform.postScale(scaleX, scaleY, centerX, centerY);
                transform.postScale(-1f, 1f, centerX, centerY);
                previewView.setTransform(transform);
            }
        });
    }

    private void postMain(Runnable runnable) {
        mMainHandler.post(runnable);
    }

    @Override
    public void close() {
        mClosed = true;
        mRecording = false;
        mBusy = false;
        Handler handler = mCameraHandler;
        if (handler != null) {
            handler.post(new Runnable() {
                @Override
                public void run() {
                    closeCameraGraph();
                }
            });
        } else {
            closeCameraGraph();
        }
        mDecodeExecutor.shutdownNow();
    }
}
