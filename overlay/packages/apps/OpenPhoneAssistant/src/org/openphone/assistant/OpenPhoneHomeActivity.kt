package org.openphone.assistant

import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.view.View
import org.openphone.assistant.context.ContextIndexStore
import java.util.Locale

/**
 * OpenPhone's normal Android HOME activity.
 *
 * The activity intentionally uses an application window rather than a
 * full-screen overlay. Android therefore retains ownership of keyguard,
 * notifications, IME, recents, system dialogs, and task navigation.
 */
class OpenPhoneHomeActivity : AssistantActivityBackend() {
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
