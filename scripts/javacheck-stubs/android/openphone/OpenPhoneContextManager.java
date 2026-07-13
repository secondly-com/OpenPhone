// Compile-check stub. The real class is added to frameworks/base by the
// OpenPhone patch stack and is only available in the full Android tree.
// scripts/check-assistant-java.sh compiles assistant sources against this
// stub to catch syntax/reference breaks without a full Android build.
package android.openphone;

public final class OpenPhoneContextManager {
    private OpenPhoneContextManager() {
        throw new UnsupportedOperationException("compile-check stub");
    }

    public String getServiceStatus() {
        throw new UnsupportedOperationException("compile-check stub");
    }

    public String insertEvent(String eventJson) {
        throw new UnsupportedOperationException("compile-check stub");
    }

    public String insertEvents(String eventsJsonArray) {
        throw new UnsupportedOperationException("compile-check stub");
    }

    public String queryEvents(String requestJson) {
        throw new UnsupportedOperationException("compile-check stub");
    }

    public String tombstoneEvent(long eventId) {
        throw new UnsupportedOperationException("compile-check stub");
    }
}
