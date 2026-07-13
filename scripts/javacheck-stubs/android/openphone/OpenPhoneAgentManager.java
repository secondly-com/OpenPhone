// Compile-check stub. The real class is added to frameworks/base by the
// OpenPhone patch stack and is only available in the full Android tree.
// scripts/check-assistant-java.sh compiles assistant sources against this
// stub to catch syntax/reference breaks without a full Android build.
package android.openphone;

public final class OpenPhoneAgentManager {
    private OpenPhoneAgentManager() {
        throw new UnsupportedOperationException("compile-check stub");
    }

    public String getServiceStatus() {
        throw new UnsupportedOperationException("compile-check stub");
    }

    public String startTask(String taskRequestJson) {
        throw new UnsupportedOperationException("compile-check stub");
    }

    public String stopTask(String taskId, String reasonJson) {
        throw new UnsupportedOperationException("compile-check stub");
    }

    public String getScreenContext(String taskId) {
        throw new UnsupportedOperationException("compile-check stub");
    }

    public String getScreen(String taskId, String requestJson) {
        throw new UnsupportedOperationException("compile-check stub");
    }

    public String watchScreen(String taskId, String requestJson) {
        throw new UnsupportedOperationException("compile-check stub");
    }

    public String executeAction(String taskId, String actionRequestJson) {
        throw new UnsupportedOperationException("compile-check stub");
    }

    public String confirmAction(String pendingActionId, boolean approved) {
        throw new UnsupportedOperationException("compile-check stub");
    }

    public String evaluateCapability(String capabilityId) {
        throw new UnsupportedOperationException("compile-check stub");
    }

    public String getPointerEvents(String taskId, int maxEvents) {
        throw new UnsupportedOperationException("compile-check stub");
    }

    public String getAuditLog(int maxEvents) {
        throw new UnsupportedOperationException("compile-check stub");
    }

    public String submitUiTreeSnapshot(String snapshotJson) {
        throw new UnsupportedOperationException("compile-check stub");
    }

    public String getUiTreeSnapshot() {
        throw new UnsupportedOperationException("compile-check stub");
    }
}
