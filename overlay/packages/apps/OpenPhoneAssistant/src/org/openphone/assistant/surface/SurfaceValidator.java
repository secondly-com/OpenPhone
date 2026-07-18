package org.openphone.assistant.surface;

import android.content.Context;

import org.json.JSONArray;
import org.json.JSONObject;
import org.openphone.assistant.actions.ActionRegistry;
import org.openphone.assistant.actions.ToolCatalog;

import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Iterator;
import java.util.Set;
import java.util.regex.Pattern;

/** Phone-owned structural, policy-binding, and resource validator for Surface V1. */
public final class SurfaceValidator {
    public static final int MAX_BYTES = 256 * 1024;
    public static final int MAX_NODES = 120;
    public static final int MAX_DEPTH = 12;
    public static final int MAX_TEXT_CHARS = 24000;
    public static final int MAX_IMAGES = 4;
    public static final int MAX_ACTIONS = 24;

    private static final Pattern SURFACE_ID =
            Pattern.compile("^surface-[A-Za-z0-9._-]{1,120}$");
    private static final Pattern ACTION_ID =
            Pattern.compile("^[A-Za-z][A-Za-z0-9._-]{0,119}$");
    private static final Pattern ARTIFACT_ID =
            Pattern.compile("^artifact-[A-Za-z0-9._-]{1,120}$");
    private static final Set<String> PRESENTATIONS = set("full", "sheet", "inline");
    private static final Set<String> SENSITIVITY =
            set("public", "personal", "sensitive", "restricted");
    private static final Set<String> COMPONENT_TYPES = set(
            "column", "row", "spacer", "divider", "scroll",
            "text", "icon", "image", "badge", "progress",
            "card", "list", "list_item", "timeline",
            "button", "chip", "choice_group", "toggle", "text_input",
            "native_handoff", "confirmation", "capability_disclosure", "error");
    private static final Set<String> COMPONENT_KEYS = set(
            "type", "children", "items", "text", "title", "subtitle", "label",
            "message", "content_description", "style", "tone", "density", "spacing",
            "action_id", "input_key", "placeholder", "value", "checked", "progress",
            "artifact", "icon", "options", "native_target", "capability");
    private static final Set<String> ROOT_KEYS = set(
            "schema", "surface_id", "revision", "session_id", "runtime", "title",
            "presentation", "expires_at", "sensitivity", "body", "actions",
            "artifacts", "created_at");
    private static final Set<String> ACTION_KEYS = set(
            "label", "tool", "params", "reason", "requires_confirmation");
    private static final Set<String> TEXT_STYLES =
            set("title", "headline", "body", "caption");
    private static final Set<String> TONES =
            set("primary", "secondary", "warning", "danger");
    private static final Set<String> DENSITIES = set("compact", "comfortable");
    private static final Set<String> SPACING = set("none", "xs", "sm", "md", "lg", "xl");
    private static final Set<String> ICONS = set(
            "calendar", "message", "notification", "person", "phone", "location",
            "clock", "check", "warning", "error", "open", "agent");
    private static final Set<String> NATIVE_TARGETS =
            set("app_space", "calendar", "messages", "notifications", "dialer", "settings");
    private static final Set<String> INTERACTIVE_TYPES =
            set("button", "chip", "choice_group", "toggle", "text_input", "native_handoff",
                    "confirmation", "list_item");

    private final SurfaceArtifactStore mArtifacts;

    public SurfaceValidator(Context context) {
        mArtifacts = new SurfaceArtifactStore(context);
    }

    public SurfaceValidationResult validate(AdaptiveSurface surface) {
        if (surface == null) {
            return reject("surface_missing", "Surface document is missing or malformed.");
        }
        JSONObject raw = surface.toJson();
        if (raw.toString().getBytes(StandardCharsets.UTF_8).length > MAX_BYTES) {
            return reject("surface_too_large", "Surface exceeds the byte limit.");
        }
        String unknownRoot = firstUnknownKey(raw, ROOT_KEYS);
        if (!unknownRoot.isEmpty()) {
            return reject("unknown_root_property", "Unknown surface property: " + unknownRoot);
        }
        if (!AdaptiveSurface.SCHEMA.equals(raw.optString("schema", ""))) {
            return reject("schema_mismatch", "Unsupported surface schema.");
        }
        if (!SURFACE_ID.matcher(surface.surfaceId).matches()) {
            return reject("surface_id_invalid", "Surface identity is invalid.");
        }
        if (surface.revision < 1) {
            return reject("revision_invalid", "Surface revision must be positive.");
        }
        if (surface.sessionId.isEmpty() || surface.sessionId.length() > 160
                || surface.runtime.isEmpty() || surface.runtime.length() > 80) {
            return reject("owner_invalid", "Surface session/runtime ownership is invalid.");
        }
        if (surface.title.length() > 160
                || !PRESENTATIONS.contains(surface.presentation)
                || !SENSITIVITY.contains(surface.sensitivity)
                || surface.expiresAtMillis < 0L) {
            return reject("presentation_invalid", "Surface presentation metadata is invalid.");
        }
        if (surface.isExpired(System.currentTimeMillis())) {
            return reject("surface_expired", "Surface has expired.");
        }
        if (surface.actions.size() > MAX_ACTIONS) {
            return reject("too_many_actions", "Surface has too many actions.");
        }

        Set<String> declaredArtifacts = declaredArtifacts(surface);
        if (declaredArtifacts == null) {
            return reject("artifact_declaration_invalid", "Artifact declaration is invalid.");
        }
        ValidationState state = new ValidationState();
        SurfaceValidationResult bodyResult = validateComponent(
                raw.optJSONObject("body"), surface, declaredArtifacts, state, 1);
        if (!bodyResult.valid) {
            return bodyResult;
        }
        if (state.nodes > MAX_NODES || state.textChars > MAX_TEXT_CHARS
                || state.images > MAX_IMAGES) {
            return reject("resource_limit", "Surface exceeds a renderer resource limit.");
        }

        ToolCatalog catalog = ToolCatalog.get();
        if (!surface.actions.isEmpty() && !catalog.isLoaded()) {
            return reject("tool_registry_unavailable",
                    "Phone tool registry is unavailable; actions fail closed.");
        }
        JSONObject rawActions = raw.optJSONObject("actions");
        for (SurfaceAction action : surface.actions.values()) {
            JSONObject rawAction = rawActions == null
                    ? null : rawActions.optJSONObject(action.id);
            SurfaceValidationResult actionResult =
                    validateAction(action, rawAction, catalog);
            if (!actionResult.valid) {
                return actionResult;
            }
        }
        for (String referenced : state.referencedActions) {
            if (!surface.actions.containsKey(referenced)) {
                return reject("undeclared_action",
                        "Component references undeclared action: " + referenced);
            }
        }
        for (String declared : surface.actions.keySet()) {
            if (!state.referencedActions.contains(declared)) {
                return reject("unbound_action",
                        "Action is not bound to a component: " + declared);
            }
        }
        return SurfaceValidationResult.ok();
    }

    private SurfaceValidationResult validateComponent(JSONObject node, AdaptiveSurface surface,
            Set<String> declaredArtifacts, ValidationState state, int depth) {
        if (node == null) {
            return reject("component_missing", "Surface component must be an object.");
        }
        if (depth > MAX_DEPTH) {
            return reject("surface_too_deep", "Surface exceeds the depth limit.");
        }
        state.nodes++;
        if (state.nodes > MAX_NODES) {
            return reject("too_many_nodes", "Surface exceeds the node limit.");
        }
        String unknown = firstUnknownKey(node, COMPONENT_KEYS);
        if (!unknown.isEmpty()) {
            return reject("unknown_component_property",
                    "Unknown component property: " + unknown);
        }
        String type = node.optString("type", "");
        if (!COMPONENT_TYPES.contains(type)) {
            return reject("unknown_component", "Unknown component type: " + type);
        }
        SurfaceValidationResult tokens = validateTokens(node);
        if (!tokens.valid) {
            return tokens;
        }
        for (String key : new String[] {
                "text", "title", "subtitle", "label", "message",
                "content_description", "placeholder"
        }) {
            if (!node.has(key)) {
                continue;
            }
            Object value = node.opt(key);
            if (!(value instanceof String)) {
                return reject("text_type_invalid", key + " must be a string.");
            }
            int length = ((String) value).length();
            int perFieldLimit = ("text".equals(key) || "message".equals(key)) ? 1000 : 500;
            if (length > perFieldLimit) {
                return reject("node_text_too_long", key + " exceeds its text limit.");
            }
            state.textChars += length;
            if (state.textChars > MAX_TEXT_CHARS) {
                return reject("document_text_too_long", "Surface text exceeds its limit.");
            }
        }
        String actionId = node.optString("action_id", "");
        if (!actionId.isEmpty()) {
            if (!ACTION_ID.matcher(actionId).matches()) {
                return reject("action_id_invalid", "Component action identity is invalid.");
            }
            state.referencedActions.add(actionId);
        }
        if (INTERACTIVE_TYPES.contains(type)
                && actionId.isEmpty()
                && !"choice_group".equals(type)
                && !"text_input".equals(type)) {
            return reject("interactive_action_missing",
                    "Interactive component requires an action binding.");
        }
        if (INTERACTIVE_TYPES.contains(type)
                && accessibleLabel(node).isEmpty()) {
            return reject("accessibility_label_missing",
                    "Interactive component requires an accessible label.");
        }
        if ("text_input".equals(type)
                && !ACTION_ID.matcher(node.optString("input_key", "")).matches()) {
            return reject("input_key_invalid", "Text input requires a stable input key.");
        }
        if ("progress".equals(type)) {
            double progress = node.optDouble("progress", -1.0);
            if (progress < 0.0 || progress > 1.0) {
                return reject("progress_invalid", "Progress must be between zero and one.");
            }
        }
        if ("image".equals(type)) {
            state.images++;
            JSONObject artifact = node.optJSONObject("artifact");
            SurfaceValidationResult artifactResult = validateArtifactReference(
                    artifact, surface, declaredArtifacts);
            if (!artifactResult.valid) {
                return artifactResult;
            }
        }
        if ("icon".equals(type) && !ICONS.contains(node.optString("icon", ""))) {
            return reject("icon_invalid", "Unknown semantic icon.");
        }
        if ("native_handoff".equals(type)
                && !NATIVE_TARGETS.contains(node.optString("native_target", ""))) {
            return reject("native_target_invalid", "Native handoff target is not allowed.");
        }
        JSONArray options = node.optJSONArray("options");
        if (options != null) {
            if (options.length() > 12) {
                return reject("too_many_options", "Choice component has too many options.");
            }
            for (int i = 0; i < options.length(); i++) {
                JSONObject option = options.optJSONObject(i);
                if (option == null || option.optString("id", "").isEmpty()
                        || option.optString("label", "").isEmpty()) {
                    return reject("choice_option_invalid", "Choice option is malformed.");
                }
            }
        }
        for (String childKey : new String[] {"children", "items"}) {
            JSONArray children = node.optJSONArray(childKey);
            if (children == null) {
                continue;
            }
            if (children.length() > 32) {
                return reject("too_many_children", "Component has too many children.");
            }
            for (int i = 0; i < children.length(); i++) {
                SurfaceValidationResult childResult = validateComponent(
                        children.optJSONObject(i), surface, declaredArtifacts, state, depth + 1);
                if (!childResult.valid) {
                    return childResult;
                }
            }
        }
        return SurfaceValidationResult.ok();
    }

    private SurfaceValidationResult validateAction(SurfaceAction action, JSONObject raw,
            ToolCatalog catalog) {
        if (action == null || !ACTION_ID.matcher(action.id).matches()
                || action.label.isEmpty() || action.label.length() > 80
                || action.tool.isEmpty() || action.tool.length() > 80
                || action.reason.isEmpty() || action.reason.length() > 240) {
            return reject("action_invalid", "Surface action is malformed.");
        }
        if (raw == null) {
            return reject("action_invalid", "Surface action is missing.");
        }
        String unknown = firstUnknownKey(raw, ACTION_KEYS);
        if (!unknown.isEmpty()) {
            return reject("unknown_action_property", "Unknown action property: " + unknown);
        }
        if (!catalog.isAllowedTool(action.tool)) {
            return reject("unknown_tool", "Surface action uses an unregistered tool.");
        }
        ActionRegistry.ActionMetadata metadata = null;
        for (ActionRegistry.ActionMetadata candidate : catalog.tools()) {
            if (action.tool.equals(candidate.modelTool)) {
                metadata = candidate;
                break;
            }
        }
        if (metadata == null) {
            return reject("tool_metadata_missing", "Tool metadata is unavailable.");
        }
        if (catalog.isStateChangingTool(action.tool) && !action.requiresConfirmation) {
            return reject("mutation_disclosure_missing",
                    "Mutating surface actions must declare confirmation.");
        }
        for (String required : metadata.requiredInputs) {
            if ("reason".equals(required)) {
                continue;
            }
            if (!action.params.has(required)) {
                return reject("tool_param_missing", "Missing required tool parameter: " + required);
            }
        }
        JSONObject properties = metadata.inputSchema.optJSONObject("properties");
        Iterator<String> keys = action.params.keys();
        while (keys.hasNext()) {
            String key = keys.next();
            if (properties == null || !properties.has(key)) {
                return reject("tool_param_unknown", "Unknown tool parameter: " + key);
            }
            JSONObject property = properties.optJSONObject(key);
            if (property != null && !matchesType(action.params.opt(key),
                    property.optString("type", ""))) {
                return reject("tool_param_type", "Invalid type for tool parameter: " + key);
            }
        }
        return SurfaceValidationResult.ok();
    }

    private Set<String> declaredArtifacts(AdaptiveSurface surface) {
        Set<String> declared = new HashSet<>();
        for (int i = 0; i < surface.artifacts.length(); i++) {
            JSONObject reference = surface.artifacts.optJSONObject(i);
            if (!validArtifactReferenceShape(reference)) {
                return null;
            }
            declared.add(reference.optString("artifact_id", ""));
        }
        return declared;
    }

    private SurfaceValidationResult validateArtifactReference(JSONObject reference,
            AdaptiveSurface surface, Set<String> declaredArtifacts) {
        if (!validArtifactReferenceShape(reference)) {
            return reject("artifact_reference_invalid", "Artifact reference is malformed.");
        }
        String artifactId = reference.optString("artifact_id", "");
        if (!declaredArtifacts.contains(artifactId)) {
            return reject("artifact_undeclared", "Component uses an undeclared artifact.");
        }
        if (!mArtifacts.belongsToSession(artifactId, surface.sessionId)) {
            return reject("artifact_session_mismatch",
                    "Artifact is missing, expired, or belongs to another session.");
        }
        return SurfaceValidationResult.ok();
    }

    private static boolean validArtifactReferenceShape(JSONObject reference) {
        if (reference == null || reference.length() != 2) {
            return false;
        }
        String artifactId = reference.optString("artifact_id", "");
        String path = reference.optString("path", "");
        return ARTIFACT_ID.matcher(artifactId).matches()
                && path.matches("^\\$([.][A-Za-z0-9_-]+|\\[[0-9]+\\])*$")
                && path.length() <= 240;
    }

    private static SurfaceValidationResult validateTokens(JSONObject node) {
        if (node.has("style") && !TEXT_STYLES.contains(node.optString("style", ""))) {
            return reject("style_invalid", "Unknown semantic text style.");
        }
        if (node.has("tone") && !TONES.contains(node.optString("tone", ""))) {
            return reject("tone_invalid", "Unknown semantic tone.");
        }
        if (node.has("density") && !DENSITIES.contains(node.optString("density", ""))) {
            return reject("density_invalid", "Unknown density token.");
        }
        if (node.has("spacing") && !SPACING.contains(node.optString("spacing", ""))) {
            return reject("spacing_invalid", "Unknown spacing token.");
        }
        return SurfaceValidationResult.ok();
    }

    private static String accessibleLabel(JSONObject node) {
        for (String key : new String[] {
                "content_description", "label", "title", "text", "message", "placeholder"
        }) {
            String value = node.optString(key, "").trim();
            if (!value.isEmpty()) {
                return value;
            }
        }
        return "";
    }

    private static boolean matchesType(Object value, String type) {
        if (type == null || type.isEmpty()) {
            return true;
        }
        if ("string".equals(type)) {
            return value instanceof String;
        }
        if ("integer".equals(type)) {
            return value instanceof Integer || value instanceof Long;
        }
        if ("number".equals(type)) {
            return value instanceof Number;
        }
        if ("boolean".equals(type)) {
            return value instanceof Boolean;
        }
        if ("object".equals(type)) {
            return value instanceof JSONObject;
        }
        if ("array".equals(type)) {
            return value instanceof JSONArray;
        }
        return false;
    }

    private static String firstUnknownKey(JSONObject object, Set<String> allowed) {
        Iterator<String> keys = object.keys();
        while (keys.hasNext()) {
            String key = keys.next();
            if (!allowed.contains(key)) {
                return key;
            }
        }
        return "";
    }

    private static SurfaceValidationResult reject(String code, String message) {
        return SurfaceValidationResult.reject(code, message);
    }

    private static Set<String> set(String... values) {
        return new HashSet<>(Arrays.asList(values));
    }

    private static final class ValidationState {
        int nodes;
        int textChars;
        int images;
        final Set<String> referencedActions = new HashSet<>();
    }
}
