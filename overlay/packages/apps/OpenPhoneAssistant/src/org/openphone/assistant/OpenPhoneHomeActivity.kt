package org.openphone.assistant

import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import android.view.View
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
    override fun onCreate(savedInstanceState: Bundle?) {
        configureImmersiveWindow()
        super.onCreate(savedInstanceState)
        enterImmersiveHome()
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
