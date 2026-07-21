package org.openphone.assistant;

import android.content.Context;
import android.graphics.ImageFormat;
import android.graphics.SurfaceTexture;
import android.hardware.camera2.CameraAccessException;
import android.hardware.camera2.CameraCaptureSession;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraDevice;
import android.hardware.camera2.CameraManager;
import android.hardware.camera2.CaptureRequest;
import android.hardware.camera2.params.StreamConfigurationMap;
import android.media.Image;
import android.media.ImageReader;
import android.os.Handler;
import android.os.HandlerThread;
import android.provider.Settings;
import android.util.Log;
import android.util.Size;
import android.view.Surface;
import android.view.TextureView;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;
import java.util.UUID;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Temporary, developer-configured Silent Speech capture path for AI Home.
 *
 * <p>The front camera produces bounded JPEG frames. On release, those frames
 * are uploaded to the existing private demo decoder. The URL and bearer token
 * live in Settings.Secure on the userdebug device and are never compiled into
 * the APK.</p>
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

    static final String SECURE_DECODE_URL = "openphone_silent_speech_decode_url";
    static final String SECURE_BEARER_TOKEN = "openphone_silent_speech_bearer_token";

    private static final String TAG = "OpenPhoneSilentSpeech";
    private static final int MIN_FRAMES = 8;
    private static final int MAX_FRAMES = 300;
    private static final int MAX_RESPONSE_BYTES = 64 * 1024;
    private static final long MIN_FRAME_INTERVAL_NS = 80_000_000L;

    private final Context mContext;
    private final Listener mListener;
    private final Handler mMainHandler;
    private final ExecutorService mUploadExecutor = Executors.newSingleThreadExecutor();
    private final ArrayList<byte[]> mFrames = new ArrayList<>();

    private volatile boolean mBusy;
    private volatile boolean mRecording;
    private volatile HttpURLConnection mActiveConnection;
    private HandlerThread mCameraThread;
    private Handler mCameraHandler;
    private CameraDevice mCamera;
    private CameraCaptureSession mSession;
    private ImageReader mImageReader;
    private TextureView mPreviewView;
    private Surface mPreviewSurface;
    private Size mCaptureSize;
    private boolean mSessionCreating;
    private long mLastFrameTimestampNs;
    private int mSensorOrientation;

    SilentSpeechCameraClient(Context context, Listener listener) {
        mContext = context.getApplicationContext();
        mListener = listener;
        mMainHandler = new Handler(context.getMainLooper());
    }

    boolean isRecording() {
        return mRecording;
    }

    boolean isBusy() {
        return mBusy;
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
        if (mBusy) {
            return;
        }
        mBusy = true;
        mRecording = true;
        mFrames.clear();
        mLastFrameTimestampNs = 0L;
        postMain(new Runnable() {
            @Override
            public void run() {
                mListener.onCaptureStarting();
            }
        });

        mCameraThread = new HandlerThread("OpenPhoneSilentSpeechCamera");
        mCameraThread.start();
        mCameraHandler = new Handler(mCameraThread.getLooper());
        mCameraHandler.post(new Runnable() {
            @Override
            public void run() {
                openFrontCamera();
            }
        });
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
        HttpURLConnection connection = mActiveConnection;
        if (connection != null) {
            connection.disconnect();
        }
        Handler handler = mCameraHandler;
        if (handler != null) {
            handler.post(new Runnable() {
                @Override
                public void run() {
                    closeCameraGraph();
                    mFrames.clear();
                    mBusy = false;
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
        try {
            CameraManager manager = (CameraManager) mContext.getSystemService(Context.CAMERA_SERVICE);
            String cameraId = frontCameraId(manager);
            CameraCharacteristics characteristics = manager.getCameraCharacteristics(cameraId);
            Integer orientation = characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION);
            mSensorOrientation = orientation == null ? 0 : orientation;
            Size size = captureSize(characteristics);
            mCaptureSize = size;
            mImageReader = ImageReader.newInstance(
                    size.getWidth(), size.getHeight(), ImageFormat.JPEG, 4);
            mImageReader.setOnImageAvailableListener(this::onImageAvailable, mCameraHandler);
            TextureView preview = mPreviewView;
            if (preview != null && preview.isAvailable()) {
                preparePreviewSurface(preview.getSurfaceTexture());
            }
            manager.openCamera(cameraId, new CameraDevice.StateCallback() {
                @Override
                public void onOpened(CameraDevice camera) {
                    if (!mRecording) {
                        camera.close();
                        return;
                    }
                    mCamera = camera;
                    maybeCreateCaptureSession();
                }

                @Override
                public void onDisconnected(CameraDevice camera) {
                    camera.close();
                    fail("The front camera disconnected.");
                }

                @Override
                public void onError(CameraDevice camera, int error) {
                    camera.close();
                    fail("The front camera could not start (" + error + ").");
                }
            }, mCameraHandler);
        } catch (SecurityException e) {
            fail("Camera permission is required for Silent Speech.");
        } catch (CameraAccessException | IllegalStateException e) {
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
                releasePreviewSurface();
                texture.setDefaultBufferSize(
                        mCaptureSize.getWidth(), mCaptureSize.getHeight());
                mPreviewSurface = new Surface(texture);
                maybeCreateCaptureSession();
            }
        });
    }

    private void maybeCreateCaptureSession() {
        if (mSessionCreating || mSession != null || mCamera == null
                || mImageReader == null || mPreviewSurface == null) {
            return;
        }
        mSessionCreating = true;
        try {
            mCamera.createCaptureSession(
                    java.util.Arrays.asList(mPreviewSurface, mImageReader.getSurface()),
                    new CameraCaptureSession.StateCallback() {
                        @Override
                        public void onConfigured(CameraCaptureSession session) {
                            mSessionCreating = false;
                            if (!mRecording || mCamera == null || mImageReader == null) {
                                session.close();
                                return;
                            }
                            mSession = session;
                            try {
                                CaptureRequest.Builder request = mCamera.createCaptureRequest(
                                        CameraDevice.TEMPLATE_RECORD);
                                request.addTarget(mPreviewSurface);
                                request.addTarget(mImageReader.getSurface());
                                request.set(CaptureRequest.CONTROL_MODE,
                                        CaptureRequest.CONTROL_MODE_AUTO);
                                request.set(CaptureRequest.CONTROL_AF_MODE,
                                        CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO);
                                request.set(CaptureRequest.JPEG_QUALITY, (byte) 65);
                                request.set(CaptureRequest.JPEG_ORIENTATION, mSensorOrientation);
                                session.setRepeatingRequest(request.build(), null, mCameraHandler);
                                postMain(new Runnable() {
                                    @Override
                                    public void run() {
                                        mListener.onCaptureStarted();
                                    }
                                });
                            } catch (CameraAccessException | IllegalStateException e) {
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

    private void onImageAvailable(ImageReader reader) {
        Image image = null;
        try {
            image = reader.acquireLatestImage();
            if (image == null || !mRecording) {
                return;
            }
            long timestamp = image.getTimestamp();
            if (mLastFrameTimestampNs != 0L
                    && timestamp - mLastFrameTimestampNs < MIN_FRAME_INTERVAL_NS) {
                return;
            }
            mLastFrameTimestampNs = timestamp;
            ByteBuffer buffer = image.getPlanes()[0].getBuffer();
            byte[] jpeg = new byte[buffer.remaining()];
            buffer.get(jpeg);
            mFrames.add(jpeg);
            int count = mFrames.size();
            postMain(new Runnable() {
                @Override
                public void run() {
                    mListener.onFrameCaptured(count);
                }
            });
            if (count >= MAX_FRAMES) {
                finishCapture(true);
            }
        } catch (RuntimeException e) {
            Log.w(TAG, "Unable to read camera frame", e);
        } finally {
            if (image != null) {
                image.close();
            }
        }
    }

    private void finishCapture(boolean decode) {
        if (!mRecording) {
            return;
        }
        mRecording = false;
        closeCameraGraph();
        ArrayList<byte[]> captured = new ArrayList<>(mFrames);
        mFrames.clear();
        if (!decode) {
            mBusy = false;
            return;
        }
        if (captured.size() < MIN_FRAMES) {
            mBusy = false;
            postError("Hold still and mouth your request a little longer.");
            return;
        }
        postMain(new Runnable() {
            @Override
            public void run() {
                mListener.onDecoding(captured.size());
            }
        });
        mUploadExecutor.execute(new Runnable() {
            @Override
            public void run() {
                upload(captured);
            }
        });
    }

    private void upload(List<byte[]> frames) {
        String urlValue = Settings.Secure.getString(
                mContext.getContentResolver(), SECURE_DECODE_URL);
        String token = Settings.Secure.getString(
                mContext.getContentResolver(), SECURE_BEARER_TOKEN);
        if (urlValue == null || urlValue.trim().isEmpty()
                || token == null || token.trim().isEmpty()) {
            finishUploadWithError("Silent Speech demo access is not configured on this phone.");
            return;
        }

        HttpURLConnection connection = null;
        try {
            URL url = new URL(urlValue.trim());
            if (!"https".equalsIgnoreCase(url.getProtocol())) {
                throw new IOException("HTTPS is required");
            }
            String boundary = "OpenPhoneSilentSpeech-" + UUID.randomUUID();
            connection = (HttpURLConnection) url.openConnection();
            mActiveConnection = connection;
            connection.setConnectTimeout(15_000);
            connection.setReadTimeout(120_000);
            connection.setRequestMethod("POST");
            connection.setDoOutput(true);
            connection.setChunkedStreamingMode(64 * 1024);
            connection.setRequestProperty("Authorization", "Bearer " + token.trim());
            connection.setRequestProperty("Content-Type",
                    "multipart/form-data; boundary=" + boundary);
            try (OutputStream output = connection.getOutputStream()) {
                for (int i = 0; i < frames.size(); i++) {
                    writeUtf8(output, "--" + boundary + "\r\n");
                    writeUtf8(output, "Content-Disposition: form-data; name=\"frames\"; "
                            + "filename=\"frame_" + String.format(Locale.US, "%06d", i)
                            + ".jpg\"\r\n");
                    writeUtf8(output, "Content-Type: image/jpeg\r\n\r\n");
                    output.write(frames.get(i));
                    writeUtf8(output, "\r\n");
                }
                writeUtf8(output, "--" + boundary + "--\r\n");
            }

            int status = connection.getResponseCode();
            InputStream stream = status >= 200 && status < 300
                    ? connection.getInputStream() : connection.getErrorStream();
            String body = readBounded(stream, MAX_RESPONSE_BYTES);
            JSONObject response = new JSONObject(body);
            String text = response.optString("text", "").trim();
            if (status < 200 || status >= 300 || text.isEmpty()) {
                String detail = response.optString("error", "Silent Speech could not decode this take.");
                throw new IOException(detail);
            }
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
            mActiveConnection = null;
            if (connection != null) {
                connection.disconnect();
            }
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
        mFrames.clear();
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
        ImageReader reader = mImageReader;
        mImageReader = null;
        if (reader != null) {
            reader.close();
        }
        releasePreviewSurface();
        mCaptureSize = null;
        mSessionCreating = false;
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
        if (map == null || map.getOutputSizes(ImageFormat.JPEG) == null) {
            return new Size(640, 480);
        }
        ArrayList<Size> candidates = new ArrayList<>();
        Collections.addAll(candidates, map.getOutputSizes(ImageFormat.JPEG));
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

    private void releasePreviewSurface() {
        Surface surface = mPreviewSurface;
        mPreviewSurface = null;
        if (surface != null) {
            surface.release();
        }
    }

    private void postMain(Runnable runnable) {
        mMainHandler.post(runnable);
    }

    private static void writeUtf8(OutputStream output, String value) throws IOException {
        output.write(value.getBytes(StandardCharsets.UTF_8));
    }

    private static String readBounded(InputStream input, int maxBytes) throws IOException {
        if (input == null) {
            return "{}";
        }
        try (InputStream stream = input; ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[4096];
            int total = 0;
            int read;
            while ((read = stream.read(buffer)) != -1) {
                total += read;
                if (total > maxBytes) {
                    throw new IOException("Silent Speech returned an oversized response");
                }
                output.write(buffer, 0, read);
            }
            return output.toString(StandardCharsets.UTF_8.name());
        }
    }

    @Override
    public void close() {
        cancel();
        mUploadExecutor.shutdownNow();
    }
}
