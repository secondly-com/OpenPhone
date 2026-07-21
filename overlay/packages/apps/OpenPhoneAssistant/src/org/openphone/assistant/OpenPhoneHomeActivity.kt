package org.openphone.assistant

import android.Manifest
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.view.View
import android.view.TextureView
import android.view.WindowInsets
import android.view.WindowInsetsController
import android.view.WindowManager
import org.openphone.assistant.context.ContextIndexStore
import java.util.Locale

/**
 * OpenPhone's normal Android HOME activity.
 *
 * The activity owns the full display while it is foreground, but remains a
 * normal application window rather than a system overlay. Android therefore
 * retains ownership of secure keyguard, transient system bars, IME, recents,
 * system dialogs, and task navigation.
 */
class OpenPhoneHomeActivity : AssistantActivityBackend() {
    private var interfacesAuthClient: InterfacesAuthClient? = null
    private var silentSpeechClient: SilentSpeechCameraClient? = null
    private var startAfterCameraPermission = false

    override fun onCreate(savedInstanceState: Bundle?) {
        configureImmersiveWindow()
        super.onCreate(savedInstanceState)
        interfacesAuthClient = InterfacesAuthClient(
            this,
            InterfacesAuthClient.Listener { signedIn, busy, message, error ->
                OpenPhoneHomeComposeHost.setInterfacesConnectionState(
                    signedIn,
                    busy,
                    message,
                    error,
                )
            },
        )
        OpenPhoneHomeComposeHost.setInterfacesConnectionState(
            interfacesAuthClient?.isSignedIn == true,
            false,
            "",
            false,
        )
        silentSpeechClient = SilentSpeechCameraClient(
            this,
            interfacesAuthClient,
            object : SilentSpeechCameraClient.Listener {
                override fun onCaptureStarting() {
                    OpenPhoneHomeComposeHost.beginSilentSpeechCapture()
                }

                override fun onCaptureStarted() {
                    OpenPhoneHomeComposeHost.silentSpeechCameraReady()
                }

                override fun onFrameCaptured(count: Int) {
                    OpenPhoneHomeComposeHost.updateSilentSpeechFrame(count)
                }

                override fun onDecoding(frameCount: Int) {
                    OpenPhoneHomeComposeHost.beginSilentSpeechDecode(frameCount)
                }

                override fun onDecoded(text: String) {
                    onSilentSpeechDecoded(text)
                }

                override fun onError(message: String) {
                    OpenPhoneHomeComposeHost.failSilentSpeech(message)
                }

                override fun onCancelled() {
                    OpenPhoneHomeComposeHost.cancelSilentSpeech()
                }
            },
        )
        enterImmersiveHome()
    }

    override fun onDestroy() {
        silentSpeechClient?.close()
        silentSpeechClient = null
        interfacesAuthClient?.close()
        interfacesAuthClient = null
        super.onDestroy()
    }

    override fun onResume() {
        super.onResume()
        enterImmersiveHome()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) enterImmersiveHome()
    }

    override fun isHomeSurface(): Boolean = true

    override fun createActivityContentView(): View = OpenPhoneHomeComposeHost.createView(this)

    fun attachSilentSpeechPreview(preview: TextureView) {
        silentSpeechClient?.attachPreview(preview)
    }

    fun detachSilentSpeechPreview(preview: TextureView) {
        silentSpeechClient?.detachPreview(preview)
    }

    override fun onHomeVoiceHoldStarted() {
        val client = silentSpeechClient ?: return
        if (client.isRecording || client.isBusy) return
        if (interfacesAuthClient?.isSignedIn != true) {
            connectInterfaces()
            return
        }
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            startAfterCameraPermission = true
            requestPermissions(arrayOf(Manifest.permission.CAMERA), REQUEST_SILENT_SPEECH_CAMERA)
            OpenPhoneHomeComposeHost.showSilentSpeechStatus("Allow the front camera to continue.")
            return
        }
        client.start()
    }

    override fun onHomeVoiceHoldFinished() {
        silentSpeechClient?.stopAndDecode()
    }

    override fun onHomeVoiceHoldCancelled() {
        silentSpeechClient?.cancel()
    }

    fun onHomeMicrophonePressed() {
        super.onComposeMic()
    }

    fun onHomeMicrophoneStopped() {
        super.onComposeStop()
    }

    fun connectInterfaces() {
        val auth = interfacesAuthClient ?: return
        if (auth.isSignedIn) {
            OpenPhoneHomeComposeHost.showSilentSpeechStatus("Interfaces connected")
            return
        }
        auth.signIn(this)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (requestCode != REQUEST_SILENT_SPEECH_CAMERA) {
            super.onRequestPermissionsResult(requestCode, permissions, grantResults)
            return
        }
        val granted = grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED
        if (granted && startAfterCameraPermission) {
            startAfterCameraPermission = false
            silentSpeechClient?.start()
        } else {
            startAfterCameraPermission = false
            OpenPhoneHomeComposeHost.failSilentSpeech(
                "Camera permission is required for Silent Speech.",
            )
        }
    }

    fun submitHomeText(text: String) {
        if (requestsAppSpace(text)) {
            if (!openAppSpace()) {
                notifyHomeMessage("App Space is unavailable. Open Home settings to choose a launcher.")
            }
            return
        }
        onHomeTextSubmitted(text)
    }

    fun openAppSpace(): Boolean {
        val candidates = resources.getStringArray(R.array.openphone_app_space_components)
        for (flattened in candidates) {
            val component = ComponentName.unflattenFromString(flattened) ?: continue
            if (!isActivityAvailable(component)) continue
            val intent = Intent(Intent.ACTION_MAIN)
                .setComponent(component)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
            return try {
                recordHomeTransition("app_space", component.flattenToShortString())
                startActivity(intent)
                true
            } catch (_: RuntimeException) {
                false
            }
        }
        return false
    }

    fun openAssistant() {
        startActivity(
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
        )
    }

    private fun isActivityAvailable(component: ComponentName): Boolean =
        try {
            packageManager.getActivityInfo(component, PackageManager.MATCH_DISABLED_COMPONENTS)
            true
        } catch (_: PackageManager.NameNotFoundException) {
            false
        }

    private fun recordHomeTransition(destination: String, detail: String) {
        ContextIndexStore(this).recordAgentEvent(
            "assistant.home.transition",
            "OpenPhone Home transition",
            destination,
            "",
            """{"destination":"$destination","detail":"${detail.replace("\"", "")}"}""",
        )
    }

    private fun notifyHomeMessage(message: String) {
        OpenPhoneHomeComposeHost.deliverLocalMessage(message)
    }

    private fun configureImmersiveWindow() {
        window.setDecorFitsSystemWindows(false)
        window.attributes = window.attributes.apply {
            layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS
        }
    }

    private fun enterImmersiveHome() {
        configureImmersiveWindow()
        window.insetsController?.let { controller ->
            controller.systemBarsBehavior =
                WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            controller.hide(
                WindowInsets.Type.statusBars() or WindowInsets.Type.navigationBars(),
            )
        }
    }

    companion object {
        private const val REQUEST_SILENT_SPEECH_CAMERA = 2101

        private fun requestsAppSpace(text: String): Boolean {
            val clean = text.trim().lowercase(Locale.US)
            return clean == "apps" ||
                clean == "open apps" ||
                clean == "show apps" ||
                clean == "show my apps" ||
                clean == "open my apps" ||
                clean == "app space" ||
                clean == "open app space"
        }
    }
}
