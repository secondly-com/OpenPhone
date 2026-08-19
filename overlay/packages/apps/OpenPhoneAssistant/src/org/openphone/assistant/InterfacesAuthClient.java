package org.openphone.assistant;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.content.SharedPreferences;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import android.util.Log;

import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.InetAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/**
 * Firebase/Interfaces session for the OpenPhone surface.
 *
 * <p>Sign-in uses the same browser + loopback PKCE flow as Interfaces for Mac.
 * Firebase refresh credentials and the native device-session token are encrypted
 * with a non-exportable Android Keystore key. The phone never receives a model
 * identifier: the authenticated API derives the current model from the UID.</p>
 */
final class InterfacesAuthClient implements AutoCloseable {
    interface Listener {
        void onStateChanged(boolean signedIn, boolean busy, String message, boolean error);
    }

    private static final String TAG = "OpenPhoneInterfacesAuth";
    private static final String CLIENT_ID = "interfaces-openphone";
    private static final String PLATFORM_BASE_URL = "https://cloud.interfaces.inc";
    private static final String NATIVE_CONFIG_URL = PLATFORM_BASE_URL + "/api/native/config";
    private static final int MAX_JSON_BYTES = 128 * 1024;
    private static final int CALLBACK_TIMEOUT_MS = 5 * 60_000;
    private static final long TOKEN_SAFETY_SECONDS = 120L;
    private static final String PREFS = "interfaces_native_auth";
    private static final String PREF_ENCRYPTED_CREDENTIAL = "credential_v1";
    private static final String KEY_ALIAS = "interfaces_openphone_native_auth_v1";

    private final Context mContext;
    private final Listener mListener;
    private final Handler mMainHandler;
    private final ExecutorService mExecutor = Executors.newSingleThreadExecutor();
    private final AtomicBoolean mSigningIn = new AtomicBoolean(false);
    private final Object mSessionLock = new Object();
    private final SecureRandom mRandom = new SecureRandom();

    private StoredCredential mCredential;
    private ActiveSession mSession;
    private volatile HttpURLConnection mActiveConnection;

    InterfacesAuthClient(Context context, Listener listener) {
        mContext = context.getApplicationContext();
        mListener = listener;
        mMainHandler = new Handler(context.getMainLooper());
        mCredential = loadCredential();
    }

    boolean isSignedIn() {
        synchronized (mSessionLock) {
            return mCredential != null && !mCredential.refreshToken.isEmpty();
        }
    }

    void signIn(Activity activity) {
        if (!mSigningIn.compareAndSet(false, true)) {
            return;
        }
        notifyState(isSignedIn(), true, "Opening secure Interfaces sign-in…", false);
        mExecutor.execute(() -> {
            try {
                performSignIn(activity);
            } catch (Exception error) {
                Log.e(TAG, "Interfaces sign-in failed", error);
                String message = cleanMessage(error,
                        "Interfaces could not connect this phone. Try again.");
                notifyState(isSignedIn(), false, message, true);
            } finally {
                mSigningIn.set(false);
            }
        });
    }

    String decodeSilentSpeech(File video) throws IOException {
        if (video == null || !video.isFile() || video.length() == 0L) {
            throw new IOException("Silent Speech did not produce a video.");
        }
        ActiveSession session = validSession();
        StoredCredential credential;
        synchronized (mSessionLock) {
            credential = mCredential;
        }
        if (credential == null) {
            throw new IOException("Connect your Interfaces account first.");
        }

        HttpURLConnection connection = null;
        try {
            URL url = httpsUrl(credential.apiBaseUrl + "/v1/decode");
            connection = (HttpURLConnection) url.openConnection();
            mActiveConnection = connection;
            connection.setConnectTimeout(15_000);
            connection.setReadTimeout(120_000);
            connection.setRequestMethod("POST");
            connection.setDoOutput(true);
            connection.setFixedLengthStreamingMode(video.length());
            connection.setRequestProperty("Authorization", "Bearer " + session.idToken);
            connection.setRequestProperty("X-Firebase-AppCheck", session.appCheckToken);
            connection.setRequestProperty("Content-Type", "video/mp4");
            connection.setRequestProperty("X-Interfaces-Client", CLIENT_ID);
            try (InputStream input = new FileInputStream(video);
                    OutputStream output = connection.getOutputStream()) {
                copy(input, output);
            }
            int status = connection.getResponseCode();
            String body = readBounded(responseStream(connection, status), MAX_JSON_BYTES);
            JSONObject response = jsonObject(body);
            String text = response.optString("text", "").trim();
            if (status < 200 || status >= 300 || text.isEmpty()) {
                throw new IOException(apiError(response,
                        "Silent Speech could not decode this take."));
            }
            return text;
        } finally {
            mActiveConnection = null;
            if (connection != null) {
                connection.disconnect();
            }
        }
    }

    private void performSignIn(Activity activity) throws Exception {
        NativeConfig config = fetchNativeConfig();
        String verifier = randomUrlSafe(32);
        String state = randomUrlSafe(32);
        String challenge = base64Url(MessageDigest.getInstance("SHA-256")
                .digest(verifier.getBytes(StandardCharsets.UTF_8)));

        try (ServerSocket server = new ServerSocket(
                0, 1, InetAddress.getByName("127.0.0.1"))) {
            server.setSoTimeout(CALLBACK_TIMEOUT_MS);
            String redirectUri = "http://127.0.0.1:" + server.getLocalPort() + "/callback";
            Uri authorizeUri = Uri.parse(PLATFORM_BASE_URL + "/native/openphone")
                    .buildUpon()
                    .appendQueryParameter("client_id", CLIENT_ID)
                    .appendQueryParameter("redirect_uri", redirectUri)
                    .appendQueryParameter("state", state)
                    .appendQueryParameter("code_challenge", challenge)
                    .appendQueryParameter("code_challenge_method", "S256")
                    .appendQueryParameter("device_name", deviceName())
                    .build();
            openBrowser(activity, authorizeUri);
            String code = receiveCallback(server, state);
            NativeToken nativeToken = exchangeNativeCode(config, code, verifier);
            FirebaseToken firebase = exchangeFirebaseCustomToken(
                    config.firebaseApiKey, nativeToken.customToken);
            long now = unixSeconds();
            StoredCredential stored = new StoredCredential(
                    config.apiBaseUrl,
                    config.firebaseApiKey,
                    nativeToken.uid.isEmpty() ? firebase.uid : nativeToken.uid,
                    firebase.refreshToken,
                    nativeToken.deviceSessionToken,
                    nativeToken.appCheckToken,
                    now + nativeToken.appCheckExpiresIn);
            saveCredential(stored);
            synchronized (mSessionLock) {
                mCredential = stored;
                mSession = new ActiveSession(
                        firebase.idToken,
                        nativeToken.appCheckToken,
                        now + firebase.expiresIn,
                        now + nativeToken.appCheckExpiresIn);
            }
            notifyState(true, false, "Interfaces connected", false);
        }
    }

    private void openBrowser(Activity activity, Uri uri) throws Exception {
        CountDownLatch opened = new CountDownLatch(1);
        AtomicReference<Exception> failure = new AtomicReference<>();
        mMainHandler.post(() -> {
            try {
                activity.startActivity(new Intent(Intent.ACTION_VIEW, uri));
            } catch (Exception error) {
                failure.set(error);
            } finally {
                opened.countDown();
            }
        });
        if (!opened.await(10, TimeUnit.SECONDS)) {
            throw new IOException("Interfaces could not open the sign-in page.");
        }
        if (failure.get() != null) {
            throw new IOException("Interfaces could not open the sign-in page.", failure.get());
        }
    }

    private static String receiveCallback(ServerSocket server, String expectedState)
            throws Exception {
        try (Socket socket = server.accept()) {
            socket.setSoTimeout(10_000);
            String requestLine = readHttpRequestLine(socket.getInputStream());
            String[] parts = requestLine.split(" ");
            if (parts.length < 2 || !"GET".equals(parts[0])) {
                writeCallbackPage(socket, false);
                throw new IOException("Interfaces received an invalid local sign-in callback.");
            }
            Uri callback = Uri.parse("http://127.0.0.1" + parts[1]);
            String code = callback.getQueryParameter("code");
            String state = callback.getQueryParameter("state");
            boolean valid = "/callback".equals(callback.getPath())
                    && code != null && code.matches("^[A-Za-z0-9_-]{43}$")
                    && expectedState.equals(state);
            writeCallbackPage(socket, valid);
            if (!valid) {
                throw new IOException("Interfaces rejected the local sign-in callback.");
            }
            return code;
        }
    }

    private NativeConfig fetchNativeConfig() throws Exception {
        JSONObject json = requestJson("GET", NATIVE_CONFIG_URL, null, null, null);
        String apiBaseUrl = json.optString("apiBaseUrl", "").replaceAll("/+$", "");
        String firebaseApiKey = json.optString("firebaseApiKey", "");
        if (apiBaseUrl.isEmpty() || firebaseApiKey.isEmpty()) {
            throw new IOException("Interfaces sign-in is not configured.");
        }
        httpsUrl(apiBaseUrl);
        return new NativeConfig(apiBaseUrl, firebaseApiKey);
    }

    private NativeToken exchangeNativeCode(
            NativeConfig config, String code, String verifier) throws Exception {
        JSONObject body = new JSONObject()
                .put("clientId", CLIENT_ID)
                .put("code", code)
                .put("codeVerifier", verifier);
        JSONObject json = requestJson(
                "POST", config.apiBaseUrl + "/v1/native-auth/token", body, null, null);
        NativeToken token = new NativeToken(
                json.optString("uid", ""),
                json.optString("customToken", ""),
                json.optString("appCheckToken", ""),
                json.optLong("appCheckExpiresIn", 7 * 24 * 60 * 60L),
                json.optString("deviceSessionToken", ""));
        if (token.uid.isEmpty() || token.customToken.isEmpty()
                || token.appCheckToken.isEmpty() || token.deviceSessionToken.isEmpty()) {
            throw new IOException("Interfaces returned an invalid sign-in response.");
        }
        return token;
    }

    private FirebaseToken exchangeFirebaseCustomToken(String apiKey, String customToken)
            throws Exception {
        JSONObject body = new JSONObject()
                .put("token", customToken)
                .put("returnSecureToken", true);
        JSONObject json = requestJson(
                "POST",
                "https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key="
                        + urlEncode(apiKey),
                body,
                null,
                null);
        FirebaseToken token = new FirebaseToken(
                json.optString("idToken", ""),
                json.optString("refreshToken", ""),
                json.optString("localId", ""),
                parseSeconds(json.opt("expiresIn"), 3_600L));
        if (token.idToken.isEmpty() || token.refreshToken.isEmpty()) {
            throw new IOException("Firebase returned an invalid sign-in response.");
        }
        return token;
    }

    private ActiveSession validSession() throws IOException {
        synchronized (mSessionLock) {
            long now = unixSeconds();
            if (mSession != null
                    && mSession.tokenExpiresAt > now + TOKEN_SAFETY_SECONDS
                    && mSession.appCheckExpiresAt > now + TOKEN_SAFETY_SECONDS) {
                return mSession;
            }
            if (mCredential == null) {
                throw new IOException("Connect your Interfaces account first.");
            }
            try {
                FirebaseToken firebase = refreshFirebase(mCredential);
                String appCheck = mCredential.appCheckToken;
                long appCheckExpiresAt = mCredential.appCheckExpiresAt;
                if (appCheckExpiresAt <= now + TOKEN_SAFETY_SECONDS) {
                    AppCheckToken refreshed = refreshAppCheck(
                            mCredential, firebase.idToken);
                    appCheck = refreshed.token;
                    appCheckExpiresAt = now + refreshed.expiresIn;
                }
                StoredCredential updated = new StoredCredential(
                        mCredential.apiBaseUrl,
                        mCredential.firebaseApiKey,
                        mCredential.uid.isEmpty() ? firebase.uid : mCredential.uid,
                        firebase.refreshToken,
                        mCredential.deviceSessionToken,
                        appCheck,
                        appCheckExpiresAt);
                saveCredential(updated);
                mCredential = updated;
                mSession = new ActiveSession(
                        firebase.idToken,
                        appCheck,
                        now + firebase.expiresIn,
                        appCheckExpiresAt);
                return mSession;
            } catch (Exception error) {
                throw new IOException(cleanMessage(error,
                        "Interfaces could not refresh this phone's account."), error);
            }
        }
    }

    private FirebaseToken refreshFirebase(StoredCredential credential) throws Exception {
        String body = "grant_type=refresh_token&refresh_token="
                + urlEncode(credential.refreshToken);
        JSONObject json = requestJson(
                "POST",
                "https://securetoken.googleapis.com/v1/token?key="
                        + urlEncode(credential.firebaseApiKey),
                null,
                "application/x-www-form-urlencoded",
                body.getBytes(StandardCharsets.UTF_8));
        FirebaseToken token = new FirebaseToken(
                json.optString("id_token", ""),
                json.optString("refresh_token", ""),
                json.optString("user_id", ""),
                parseSeconds(json.opt("expires_in"), 3_600L));
        if (token.idToken.isEmpty() || token.refreshToken.isEmpty()) {
            throw new IOException("Firebase returned an invalid refreshed session.");
        }
        return token;
    }

    private AppCheckToken refreshAppCheck(StoredCredential credential, String idToken)
            throws Exception {
        JSONObject body = new JSONObject()
                .put("clientId", CLIENT_ID)
                .put("deviceSessionToken", credential.deviceSessionToken);
        JSONObject json = requestJson(
                "POST",
                credential.apiBaseUrl + "/v1/native-auth/app-check-token",
                body,
                null,
                null,
                "Authorization",
                "Bearer " + idToken);
        String token = json.optString("appCheckToken", "");
        if (token.isEmpty()) {
            throw new IOException("Interfaces returned an invalid device token.");
        }
        return new AppCheckToken(
                token, json.optLong("appCheckExpiresIn", 7 * 24 * 60 * 60L));
    }

    private JSONObject requestJson(
            String method,
            String urlValue,
            JSONObject jsonBody,
            String contentType,
            byte[] rawBody,
            String... headers) throws Exception {
        HttpURLConnection connection = null;
        try {
            connection = (HttpURLConnection) httpsUrl(urlValue).openConnection();
            mActiveConnection = connection;
            connection.setConnectTimeout(15_000);
            connection.setReadTimeout(30_000);
            connection.setRequestMethod(method);
            connection.setRequestProperty("Accept", "application/json");
            for (int i = 0; i + 1 < headers.length; i += 2) {
                connection.setRequestProperty(headers[i], headers[i + 1]);
            }
            byte[] body = rawBody;
            if (jsonBody != null) {
                body = jsonBody.toString().getBytes(StandardCharsets.UTF_8);
                contentType = "application/json";
            }
            if (body != null) {
                connection.setDoOutput(true);
                connection.setFixedLengthStreamingMode(body.length);
                connection.setRequestProperty("Content-Type", contentType);
                try (OutputStream output = connection.getOutputStream()) {
                    output.write(body);
                }
            }
            int status = connection.getResponseCode();
            String text = readBounded(responseStream(connection, status), MAX_JSON_BYTES);
            JSONObject response = jsonObject(text);
            if (status < 200 || status >= 300) {
                throw new IOException(apiError(response,
                        "Interfaces rejected this request (" + status + ")."));
            }
            return response;
        } finally {
            mActiveConnection = null;
            if (connection != null) {
                connection.disconnect();
            }
        }
    }

    private StoredCredential loadCredential() {
        try {
            String encoded = mContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                    .getString(PREF_ENCRYPTED_CREDENTIAL, "");
            if (encoded == null || encoded.isEmpty()) {
                return null;
            }
            byte[] encrypted = Base64.decode(encoded, Base64.NO_WRAP);
            if (encrypted.length <= 12) {
                return null;
            }
            byte[] iv = new byte[12];
            byte[] ciphertext = new byte[encrypted.length - iv.length];
            System.arraycopy(encrypted, 0, iv, 0, iv.length);
            System.arraycopy(encrypted, iv.length, ciphertext, 0, ciphertext.length);
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.DECRYPT_MODE, credentialKey(), new GCMParameterSpec(128, iv));
            JSONObject json = new JSONObject(new String(
                    cipher.doFinal(ciphertext), StandardCharsets.UTF_8));
            StoredCredential credential = StoredCredential.fromJson(json);
            return credential.isUsable() ? credential : null;
        } catch (Exception error) {
            Log.w(TAG, "Unable to restore Interfaces credential", error);
            return null;
        }
    }

    private void saveCredential(StoredCredential credential) throws Exception {
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, credentialKey());
        byte[] ciphertext = cipher.doFinal(
                credential.toJson().toString().getBytes(StandardCharsets.UTF_8));
        byte[] iv = cipher.getIV();
        byte[] combined = new byte[iv.length + ciphertext.length];
        System.arraycopy(iv, 0, combined, 0, iv.length);
        System.arraycopy(ciphertext, 0, combined, iv.length, ciphertext.length);
        SharedPreferences preferences = mContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        if (!preferences.edit().putString(
                PREF_ENCRYPTED_CREDENTIAL,
                Base64.encodeToString(combined, Base64.NO_WRAP)).commit()) {
            throw new IOException("Interfaces could not save this phone's account.");
        }
    }

    private static SecretKey credentialKey() throws Exception {
        KeyStore store = KeyStore.getInstance("AndroidKeyStore");
        store.load(null);
        KeyStore.Entry existing = store.getEntry(KEY_ALIAS, null);
        if (existing instanceof KeyStore.SecretKeyEntry) {
            return ((KeyStore.SecretKeyEntry) existing).getSecretKey();
        }
        KeyGenerator generator = KeyGenerator.getInstance(
                KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
        generator.init(new KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setUserAuthenticationRequired(false)
                .build());
        return generator.generateKey();
    }

    private void notifyState(
            boolean signedIn, boolean busy, String message, boolean error) {
        mMainHandler.post(() -> mListener.onStateChanged(signedIn, busy, message, error));
    }

    private String randomUrlSafe(int byteCount) {
        byte[] bytes = new byte[byteCount];
        mRandom.nextBytes(bytes);
        return base64Url(bytes);
    }

    private static String base64Url(byte[] value) {
        return Base64.encodeToString(
                value, Base64.URL_SAFE | Base64.NO_WRAP | Base64.NO_PADDING);
    }

    private static URL httpsUrl(String value) throws IOException {
        URL url = new URL(value);
        if (!"https".equalsIgnoreCase(url.getProtocol())) {
            throw new IOException("Interfaces requires a secure connection.");
        }
        return url;
    }

    private static String urlEncode(String value) throws IOException {
        return URLEncoder.encode(value, StandardCharsets.UTF_8.name());
    }

    private static long parseSeconds(Object value, long fallback) {
        if (value instanceof Number) {
            return ((Number) value).longValue();
        }
        if (value instanceof String) {
            try {
                return Long.parseLong((String) value);
            } catch (NumberFormatException ignored) {
            }
        }
        return fallback;
    }

    private static long unixSeconds() {
        return System.currentTimeMillis() / 1_000L;
    }

    private static String deviceName() {
        String manufacturer = Build.MANUFACTURER == null ? "OpenPhone" : Build.MANUFACTURER;
        String model = Build.MODEL == null ? "Android" : Build.MODEL;
        return (manufacturer + " " + model).trim();
    }

    private static String readHttpRequestLine(InputStream input) throws IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        int previous = -1;
        int current;
        while ((current = input.read()) != -1 && output.size() < 8_192) {
            if (previous == '\r' && current == '\n') {
                byte[] bytes = output.toByteArray();
                return new String(bytes, 0, Math.max(0, bytes.length - 1),
                        StandardCharsets.US_ASCII);
            }
            output.write(current);
            previous = current;
        }
        throw new IOException("Interfaces received an invalid local callback.");
    }

    private static void writeCallbackPage(Socket socket, boolean success) throws IOException {
        String title = success ? "Interfaces is connected" : "Connection failed";
        String message = success
                ? "Return to OpenPhone. You can close this page."
                : "Return to OpenPhone and start sign-in again.";
        String html = "<!doctype html><html><head><meta name=\"viewport\" "
                + "content=\"width=device-width,initial-scale=1\"><title>" + title + "</title>"
                + "<style>html{color-scheme:dark}body{margin:0;min-height:100vh;display:grid;"
                + "place-items:center;background:#080b12;color:#f5f8ff;font:16px system-ui}"
                + "main{max-width:28rem;padding:2rem;text-align:center}h1{font-size:2rem;"
                + "margin:.5rem}p{color:#9ca9bc;line-height:1.5}</style></head><body><main>"
                + "<h1>" + title + "</h1><p>" + message + "</p></main></body></html>";
        byte[] body = html.getBytes(StandardCharsets.UTF_8);
        String headers = "HTTP/1.1 " + (success ? "200 OK" : "400 Bad Request") + "\r\n"
                + "Content-Type: text/html; charset=utf-8\r\n"
                + "Cache-Control: no-store\r\n"
                + "Content-Length: " + body.length + "\r\nConnection: close\r\n\r\n";
        OutputStream output = socket.getOutputStream();
        output.write(headers.getBytes(StandardCharsets.US_ASCII));
        output.write(body);
        output.flush();
    }

    private static InputStream responseStream(HttpURLConnection connection, int status)
            throws IOException {
        return status >= 200 && status < 300
                ? connection.getInputStream() : connection.getErrorStream();
    }

    private static JSONObject jsonObject(String value) throws IOException {
        try {
            return new JSONObject(value == null || value.trim().isEmpty() ? "{}" : value);
        } catch (Exception error) {
            throw new IOException("Interfaces returned an invalid response.", error);
        }
    }

    private static String apiError(JSONObject response, String fallback) {
        JSONObject error = response.optJSONObject("error");
        if (error != null) {
            String message = error.optString("message", "").trim();
            if (!message.isEmpty()) {
                return message;
            }
        }
        String direct = response.optString("error", "").trim();
        return direct.isEmpty() ? fallback : direct;
    }

    private static String cleanMessage(Exception error, String fallback) {
        String message = error.getMessage();
        return message == null || message.trim().isEmpty() ? fallback : message.trim();
    }

    private static String readBounded(InputStream input, int maxBytes) throws IOException {
        if (input == null) {
            return "{}";
        }
        try (InputStream stream = input;
                ByteArrayOutputStream output = new ByteArrayOutputStream()) {
            byte[] buffer = new byte[4_096];
            int total = 0;
            int read;
            while ((read = stream.read(buffer)) != -1) {
                total += read;
                if (total > maxBytes) {
                    throw new IOException("Interfaces returned an oversized response.");
                }
                output.write(buffer, 0, read);
            }
            return output.toString(StandardCharsets.UTF_8.name());
        }
    }

    private static void copy(InputStream input, OutputStream output) throws IOException {
        byte[] buffer = new byte[64 * 1_024];
        int read;
        while ((read = input.read(buffer)) != -1) {
            output.write(buffer, 0, read);
        }
    }

    @Override
    public void close() {
        HttpURLConnection connection = mActiveConnection;
        if (connection != null) {
            connection.disconnect();
        }
        mExecutor.shutdownNow();
    }

    private static final class NativeConfig {
        final String apiBaseUrl;
        final String firebaseApiKey;

        NativeConfig(String apiBaseUrl, String firebaseApiKey) {
            this.apiBaseUrl = apiBaseUrl;
            this.firebaseApiKey = firebaseApiKey;
        }
    }

    private static final class NativeToken {
        final String uid;
        final String customToken;
        final String appCheckToken;
        final long appCheckExpiresIn;
        final String deviceSessionToken;

        NativeToken(String uid, String customToken, String appCheckToken,
                long appCheckExpiresIn, String deviceSessionToken) {
            this.uid = uid;
            this.customToken = customToken;
            this.appCheckToken = appCheckToken;
            this.appCheckExpiresIn = appCheckExpiresIn;
            this.deviceSessionToken = deviceSessionToken;
        }
    }

    private static final class FirebaseToken {
        final String idToken;
        final String refreshToken;
        final String uid;
        final long expiresIn;

        FirebaseToken(String idToken, String refreshToken, String uid, long expiresIn) {
            this.idToken = idToken;
            this.refreshToken = refreshToken;
            this.uid = uid;
            this.expiresIn = expiresIn;
        }
    }

    private static final class AppCheckToken {
        final String token;
        final long expiresIn;

        AppCheckToken(String token, long expiresIn) {
            this.token = token;
            this.expiresIn = expiresIn;
        }
    }

    private static final class ActiveSession {
        final String idToken;
        final String appCheckToken;
        final long tokenExpiresAt;
        final long appCheckExpiresAt;

        ActiveSession(String idToken, String appCheckToken,
                long tokenExpiresAt, long appCheckExpiresAt) {
            this.idToken = idToken;
            this.appCheckToken = appCheckToken;
            this.tokenExpiresAt = tokenExpiresAt;
            this.appCheckExpiresAt = appCheckExpiresAt;
        }
    }

    private static final class StoredCredential {
        final String apiBaseUrl;
        final String firebaseApiKey;
        final String uid;
        final String refreshToken;
        final String deviceSessionToken;
        final String appCheckToken;
        final long appCheckExpiresAt;

        StoredCredential(String apiBaseUrl, String firebaseApiKey, String uid,
                String refreshToken, String deviceSessionToken,
                String appCheckToken, long appCheckExpiresAt) {
            this.apiBaseUrl = apiBaseUrl;
            this.firebaseApiKey = firebaseApiKey;
            this.uid = uid;
            this.refreshToken = refreshToken;
            this.deviceSessionToken = deviceSessionToken;
            this.appCheckToken = appCheckToken;
            this.appCheckExpiresAt = appCheckExpiresAt;
        }

        boolean isUsable() {
            return !apiBaseUrl.isEmpty() && !firebaseApiKey.isEmpty()
                    && !refreshToken.isEmpty() && !deviceSessionToken.isEmpty()
                    && !appCheckToken.isEmpty();
        }

        JSONObject toJson() throws Exception {
            return new JSONObject()
                    .put("apiBaseUrl", apiBaseUrl)
                    .put("firebaseApiKey", firebaseApiKey)
                    .put("uid", uid)
                    .put("refreshToken", refreshToken)
                    .put("deviceSessionToken", deviceSessionToken)
                    .put("appCheckToken", appCheckToken)
                    .put("appCheckExpiresAt", appCheckExpiresAt);
        }

        static StoredCredential fromJson(JSONObject json) {
            return new StoredCredential(
                    json.optString("apiBaseUrl", ""),
                    json.optString("firebaseApiKey", ""),
                    json.optString("uid", ""),
                    json.optString("refreshToken", ""),
                    json.optString("deviceSessionToken", ""),
                    json.optString("appCheckToken", ""),
                    json.optLong("appCheckExpiresAt", 0L));
        }
    }
}
