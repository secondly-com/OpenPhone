#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import <dispatch/dispatch.h>
#import <arpa/inet.h>
#import <errno.h>
#import <netinet/in.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <stdarg.h>
#import <stdint.h>
#import <string.h>
#import <sys/socket.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString *const OPAIStorePath = @"/var/mobile/Library/OpenPhone";
static NSString *const OPAIAppUIDir = @"/var/mobile/Library/OpenPhone/app-ui";
static const char *OPAILogPath = "/var/mobile/Library/OpenPhone/openphone-app-introspector.log";

static long long OPAINowMs(void) {
    return (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
}

static void OPAILog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd'T'HH:mm:ssZZZZZ";
    NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                      [formatter stringFromDate:[NSDate date]],
                      message ?: @""];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length == 0) {
        return;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:@(OPAILogPath)]) {
        [[NSFileManager defaultManager] createFileAtPath:@(OPAILogPath)
                                                contents:nil
                                              attributes:nil];
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:@(OPAILogPath)];
    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
    } @catch (__unused NSException *exception) {
    }
    [handle closeFile];
}

static NSString *OPAIString(id value) {
    if ([value isKindOfClass:[NSString class]]) {
        return [(NSString *)value stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    return @"";
}

static double OPAINumberDouble(id value, double fallback) {
    return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : fallback;
}

static long long OPAINumberLongLong(id value, long long fallback) {
    return [value respondsToSelector:@selector(longLongValue)] ? [value longLongValue] : fallback;
}

static NSString *OPAIJSONStringLiteral(NSString *value) {
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:@[value ?: @""]
                                                   options:0
                                                     error:&error];
    if (!data || error) {
        return @"\"\"";
    }
    NSString *arrayJSON = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (arrayJSON.length < 2) {
        return @"\"\"";
    }
    return [arrayJSON substringWithRange:NSMakeRange(1, arrayJSON.length - 2)];
}

static NSDictionary *OPAIDictionaryFromJSONString(NSString *json) {
    if (json.length == 0) {
        return @{};
    }
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    if (data.length == 0) {
        return @{};
    }
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [value isKindOfClass:[NSDictionary class]] ? value : @{};
}

static NSString *OPAIAppBundleId(void) {
    NSString *bundleId = [[NSBundle mainBundle] bundleIdentifier];
    return bundleId.length > 0 ? bundleId : NSProcessInfo.processInfo.processName ?: @"unknown";
}

static BOOL OPAIIsWebContentProcess(void) {
    NSString *bundleId = OPAIAppBundleId();
    NSString *processName = NSProcessInfo.processInfo.processName ?: @"";
    return [bundleId isEqualToString:@"com.apple.WebKit.WebContent"] ||
            [processName isEqualToString:@"com.apple.WebKit.WebContent"] ||
            [processName containsString:@"WebKit.WebContent"];
}

static NSString *OPAIEffectiveAppBundleId(void) {
    if (OPAIIsWebContentProcess()) {
        return @"com.apple.mobilesafari";
    }
    return OPAIAppBundleId();
}

static NSString *OPAIProviderName(void) {
    return OPAIIsWebContentProcess()
            ? @"OpenPhoneAppIntrospector.WebContentAccessibility"
            : @"OpenPhoneAppIntrospector.UIKitAccessibility";
}

static NSString *OPAIInputProviderName(void) {
    return OPAIIsWebContentProcess()
            ? @"OpenPhoneAppIntrospector.WebContentInput"
            : @"OpenPhoneAppIntrospector.AppInput";
}

static NSString *OPAIElementScope(void) {
    return OPAIIsWebContentProcess() ? @"web_content_process" : @"app_process";
}

static NSString *OPAIElementRiskHint(void) {
    return OPAIIsWebContentProcess() ? @"web_content_process" : @"app_process";
}

static NSString *OPAISafeFilenameForBundleId(NSString *bundleId) {
    NSMutableString *safe = [NSMutableString string];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-"];
    for (NSUInteger index = 0; index < bundleId.length; index++) {
        unichar ch = [bundleId characterAtIndex:index];
        if ([allowed characterIsMember:ch]) {
            [safe appendFormat:@"%C", ch];
        } else {
            [safe appendString:@"_"];
        }
    }
    return safe.length > 0 ? safe : @"unknown";
}

static NSArray *OPAIBoundsArray(CGRect rect) {
    return @[
        @((double)rect.origin.x),
        @((double)rect.origin.y),
        @((double)rect.size.width),
        @((double)rect.size.height)
    ];
}

static NSArray<UIWindow *> *OPAIApplicationWindows(UIApplication *application) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        for (UIWindow *window in application.windows ?: @[]) {
            if (window && ![windows containsObject:window]) {
                [windows addObject:window];
            }
        }
#pragma clang diagnostic pop
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in application.connectedScenes ?: [NSSet set]) {
                if (![scene isKindOfClass:[UIWindowScene class]]) {
                    continue;
                }
                UIWindowScene *windowScene = (UIWindowScene *)scene;
                for (UIWindow *window in windowScene.windows ?: @[]) {
                    if (window && ![windows containsObject:window]) {
                        [windows addObject:window];
                    }
                }
            }
        }
    } @catch (__unused NSException *exception) {
    }
    return windows;
}

static NSString *OPAIViewKind(UIView *view) {
    if ([view isKindOfClass:[UIButton class]]) {
        return @"button";
    }
    if ([view isKindOfClass:[UITextField class]]) {
        return @"text_field";
    }
    if ([view isKindOfClass:[UITextView class]]) {
        return @"text_area";
    }
    if ([view isKindOfClass:[UISearchBar class]]) {
        return @"search";
    }
    if ([view isKindOfClass:[UISwitch class]]) {
        return @"switch";
    }
    if ([view isKindOfClass:[UISegmentedControl class]]) {
        return @"segmented_control";
    }
    if ([view isKindOfClass:[UILabel class]]) {
        return @"text";
    }
    if (view.isAccessibilityElement) {
        return @"accessibility_element";
    }
    return @"view";
}

static NSString *OPAIKindForAccessibilityTraits(UIAccessibilityTraits traits) {
    if ((traits & UIAccessibilityTraitButton) == UIAccessibilityTraitButton) {
        return @"button";
    }
    if ((traits & UIAccessibilityTraitLink) == UIAccessibilityTraitLink) {
        return @"link";
    }
    if ((traits & UIAccessibilityTraitKeyboardKey) == UIAccessibilityTraitKeyboardKey) {
        return @"keyboard_key";
    }
    if ((traits & UIAccessibilityTraitSearchField) == UIAccessibilityTraitSearchField) {
        return @"search_field";
    }
    if ((traits & UIAccessibilityTraitStaticText) == UIAccessibilityTraitStaticText) {
        return @"text";
    }
    return @"accessibility_element";
}

static BOOL OPAIViewIsSensitive(UIView *view) {
    if ([view isKindOfClass:[UITextField class]]) {
        return ((UITextField *)view).secureTextEntry;
    }
    UIView *textInput = nil;
    if ([view isKindOfClass:[UISearchBar class]]) {
        @try {
            textInput = ((UISearchBar *)view).searchTextField;
        } @catch (__unused NSException *exception) {
            textInput = nil;
        }
    }
    if ([textInput isKindOfClass:[UITextField class]]) {
        return ((UITextField *)textInput).secureTextEntry;
    }
    return NO;
}

static NSString *OPAIViewLabel(UIView *view) {
    BOOL sensitive = OPAIViewIsSensitive(view);
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    NSString *accessibilityLabel = OPAIString(view.accessibilityLabel);
    if (accessibilityLabel.length > 0) {
        [candidates addObject:accessibilityLabel];
    }
    if ([view isKindOfClass:[UIButton class]]) {
        NSString *title = OPAIString([(UIButton *)view titleForState:UIControlStateNormal]);
        if (title.length > 0) {
            [candidates addObject:title];
        }
    }
    if ([view isKindOfClass:[UILabel class]]) {
        NSString *text = OPAIString([(UILabel *)view text]);
        if (text.length > 0) {
            [candidates addObject:text];
        }
    }
    if ([view isKindOfClass:[UITextField class]]) {
        UITextField *field = (UITextField *)view;
        NSString *placeholder = OPAIString(field.placeholder);
        if (placeholder.length > 0) {
            [candidates addObject:placeholder];
        }
        NSString *text = sensitive ? @"" : OPAIString(field.text);
        if (text.length > 0) {
            [candidates addObject:text];
        }
    }
    if ([view isKindOfClass:[UITextView class]]) {
        NSString *text = OPAIString([(UITextView *)view text]);
        if (text.length > 0 && text.length <= 300) {
            [candidates addObject:text];
        }
    }
    NSString *accessibilityValue = sensitive ? @"" : OPAIString(view.accessibilityValue);
    if (accessibilityValue.length > 0) {
        [candidates addObject:accessibilityValue];
    }
    for (NSString *candidate in candidates) {
        if (candidate.length > 0) {
            return candidate.length <= 300 ? candidate : [candidate substringToIndex:300];
        }
    }
    return @"";
}

static NSString *OPAIEditableTextValue(UIView *view) {
    if (OPAIViewIsSensitive(view)) {
        return @"";
    }
    if ([view isKindOfClass:[UITextField class]]) {
        return OPAIString([(UITextField *)view text]);
    }
    if ([view isKindOfClass:[UITextView class]]) {
        return OPAIString([(UITextView *)view text]);
    }
    return @"";
}

static NSString *OPAIAccessibilityStringValue(id object, SEL selector) {
    if (!object || !selector || ![object respondsToSelector:selector]) {
        return @"";
    }
    id value = nil;
    @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        value = [object performSelector:selector];
#pragma clang diagnostic pop
    } @catch (__unused NSException *exception) {
        value = nil;
    }
    return OPAIString(value);
}

static CGRect OPAIAccessibilityFrameValue(id object) {
    if (!object || ![object respondsToSelector:@selector(accessibilityFrame)]) {
        return CGRectZero;
    }
    @try {
        return [object accessibilityFrame];
    } @catch (__unused NSException *exception) {
        return CGRectZero;
    }
}

static NSArray *OPAIAccessibilityChildrenForView(UIView *view) {
    if (!view) {
        return @[];
    }
    NSMutableArray *children = [NSMutableArray array];
    @try {
        NSArray *elements = [view.accessibilityElements isKindOfClass:[NSArray class]]
                ? view.accessibilityElements : nil;
        for (id element in elements ?: @[]) {
            if (element && element != view) {
                [children addObject:element];
                if (children.count >= 80) {
                    return children;
                }
            }
        }
    } @catch (__unused NSException *exception) {
    }
    if (children.count > 0 ||
            ![view respondsToSelector:@selector(accessibilityElementCount)] ||
            ![view respondsToSelector:@selector(accessibilityElementAtIndex:)]) {
        return children;
    }
    @try {
        NSInteger count = [view accessibilityElementCount];
        if (count <= 0 || count > 80) {
            return children;
        }
        for (NSInteger index = 0; index < count && children.count < 80; index++) {
            id element = [view accessibilityElementAtIndex:index];
            if (element && element != view) {
                [children addObject:element];
            }
        }
    } @catch (__unused NSException *exception) {
    }
    return children;
}

static BOOL OPAIViewLooksInteractive(UIView *view, NSString *label, NSString *identifier) {
    (void)label;
    (void)identifier;
    return view.isAccessibilityElement ||
            view.userInteractionEnabled ||
            [view isKindOfClass:[UIButton class]] ||
            [view isKindOfClass:[UITextField class]] ||
            [view isKindOfClass:[UITextView class]] ||
            [view isKindOfClass:[UISearchBar class]] ||
            [view isKindOfClass:[UISwitch class]] ||
            [view isKindOfClass:[UISegmentedControl class]];
}

static NSDictionary *OPAIElementSnapshotForView(UIView *view,
        NSString *bundleId,
        NSInteger windowIndex,
        NSUInteger elementIndex,
        CGRect bounds,
        NSString *label,
        BOOL sensitive,
        NSString *identifier) {
    NSString *safeBundle = OPAISafeFilenameForBundleId(bundleId ?: @"app");
    NSString *elementId = [NSString stringWithFormat:@"app-%@-%ld-%lu",
            safeBundle, (long)windowIndex, (unsigned long)elementIndex];
    NSMutableDictionary *element = [@{
        @"id": elementId,
        @"kind": OPAIViewKind(view),
        @"class": NSStringFromClass([view class]) ?: @"",
        @"label": sensitive ? @"" : label ?: @"",
        @"bounds": OPAIBoundsArray(bounds),
        @"enabled": @(view.userInteractionEnabled),
        @"focused": @(view.isFirstResponder),
        @"window_id": @(windowIndex),
        @"source_bundle_id": bundleId ?: @"",
        @"scope": OPAIElementScope(),
        @"sensitive": @(sensitive),
        @"risk_hint": OPAIElementRiskHint()
    } mutableCopy];
    if (identifier.length > 0) {
        element[@"view_id"] = identifier;
    }
    if (!sensitive) {
        NSString *textValue = OPAIEditableTextValue(view);
        if (textValue.length > 0) {
            element[@"value"] = textValue.length <= 300 ? textValue : [textValue substringToIndex:300];
        }
        NSString *value = OPAIString(view.accessibilityValue);
        if (value.length > 0 && !element[@"value"]) {
            element[@"value"] = value.length <= 300 ? value : [value substringToIndex:300];
        }
    }
    return element;
}

static NSDictionary *OPAIElementSnapshotForAccessibilityObject(id object,
        NSString *bundleId,
        NSInteger windowIndex,
        NSUInteger elementIndex,
        CGRect bounds) {
    NSString *safeBundle = OPAISafeFilenameForBundleId(bundleId ?: @"app");
    NSString *elementId = [NSString stringWithFormat:@"app-%@-%ld-%lu",
            safeBundle, (long)windowIndex, (unsigned long)elementIndex];
    NSString *label = OPAIAccessibilityStringValue(object, @selector(accessibilityLabel));
    NSString *value = OPAIAccessibilityStringValue(object, @selector(accessibilityValue));
    NSString *identifier = OPAIAccessibilityStringValue(object, @selector(accessibilityIdentifier));
    UIAccessibilityTraits traits = 0;
    if ([object respondsToSelector:@selector(accessibilityTraits)]) {
        @try {
            traits = [object accessibilityTraits];
        } @catch (__unused NSException *exception) {
            traits = 0;
        }
    }
    NSMutableDictionary *element = [@{
        @"id": elementId,
        @"kind": OPAIKindForAccessibilityTraits(traits),
        @"class": NSStringFromClass([object class]) ?: @"",
        @"label": label.length <= 300 ? label : [label substringToIndex:300],
        @"bounds": OPAIBoundsArray(bounds),
        @"enabled": @YES,
        @"focused": @NO,
        @"window_id": @(windowIndex),
        @"source_bundle_id": bundleId ?: @"",
        @"scope": OPAIElementScope(),
        @"sensitive": @NO,
        @"risk_hint": OPAIElementRiskHint(),
        @"accessibility_backed": @YES,
        @"accessibility_traits": @((unsigned long long)traits)
    } mutableCopy];
    if (value.length > 0) {
        element[@"value"] = value.length <= 300 ? value : [value substringToIndex:300];
    }
    if (identifier.length > 0) {
        element[@"view_id"] = identifier;
    }
    return element;
}

static NSDictionary *OPAIWindowSnapshot(UIWindow *window, NSInteger windowIndex) {
    return @{
        @"id": @(windowIndex),
        @"type": @((double)window.windowLevel),
        @"focused": @(window.isKeyWindow),
        @"active": @(!window.hidden && window.alpha >= 0.02),
        @"bounds": OPAIBoundsArray(window.bounds)
    };
}

static void OPAICollectAccessibilityChildren(UIView *view,
        NSString *bundleId,
        NSInteger windowIndex,
        NSUInteger *elementIndex,
        NSMutableArray<NSDictionary *> *interactiveElements,
        NSMutableArray<NSString *> *visibleText) {
    if (!view || !elementIndex || interactiveElements.count >= 120) {
        return;
    }
    for (id child in OPAIAccessibilityChildrenForView(view)) {
        if (interactiveElements.count >= 120) {
            return;
        }
        if ([child isKindOfClass:[UIView class]]) {
            continue;
        }
        NSString *label = OPAIAccessibilityStringValue(child, @selector(accessibilityLabel));
        NSString *value = OPAIAccessibilityStringValue(child, @selector(accessibilityValue));
        if (label.length == 0 && value.length == 0) {
            continue;
        }
        CGRect frame = OPAIAccessibilityFrameValue(child);
        if (CGRectIsEmpty(frame) || frame.size.width < 1.0 || frame.size.height < 1.0) {
            continue;
        }
        if (label.length > 0 && visibleText.count < 120 &&
                ![visibleText containsObject:label]) {
            [visibleText addObject:label.length <= 300 ? label : [label substringToIndex:300]];
        }
        if (value.length > 0 && visibleText.count < 120 &&
                ![visibleText containsObject:value]) {
            [visibleText addObject:value.length <= 300 ? value : [value substringToIndex:300]];
        }
        NSDictionary *element = OPAIElementSnapshotForAccessibilityObject(child, bundleId,
                windowIndex, *elementIndex, frame);
        (*elementIndex)++;
        [interactiveElements addObject:element];
    }
}

static void OPAICollectViewTree(UIView *view,
        UIWindow *window,
        NSString *bundleId,
        NSInteger windowIndex,
        NSInteger depth,
        NSUInteger *elementIndex,
        NSMutableArray<NSDictionary *> *interactiveElements,
        NSMutableArray<NSString *> *visibleText) {
    if (!view || depth > 32 || interactiveElements.count >= 120) {
        return;
    }
    if (view.hidden || view.alpha < 0.02) {
        return;
    }
    CGRect bounds = [view convertRect:view.bounds toView:window];
    if (CGRectIsEmpty(bounds) || bounds.size.width < 1.0 || bounds.size.height < 1.0) {
        return;
    }

    BOOL sensitive = OPAIViewIsSensitive(view);
    NSString *label = OPAIViewLabel(view);
    if (!sensitive) {
        if (label.length > 0 && visibleText.count < 120 &&
                ![visibleText containsObject:label]) {
            [visibleText addObject:label];
        }
        NSString *textValue = OPAIEditableTextValue(view);
        if (textValue.length > 0 && visibleText.count < 120 &&
                ![visibleText containsObject:textValue]) {
            [visibleText addObject:textValue.length <= 300 ? textValue : [textValue substringToIndex:300]];
        }
    }

    NSString *identifier = OPAIString(view.accessibilityIdentifier);
    BOOL interactive = OPAIViewLooksInteractive(view, label, identifier);
    BOOL editableText = [view isKindOfClass:[UITextField class]] ||
            [view isKindOfClass:[UITextView class]] ||
            [view isKindOfClass:[UISearchBar class]];
    if (interactive && (label.length > 0 || identifier.length > 0 || editableText)) {
        NSDictionary *element = OPAIElementSnapshotForView(view, bundleId, windowIndex,
                *elementIndex, bounds, label, sensitive, identifier);
        (*elementIndex)++;
        [interactiveElements addObject:element];
        if (interactiveElements.count >= 120) {
            return;
        }
    }

    OPAICollectAccessibilityChildren(view, bundleId, windowIndex, elementIndex,
            interactiveElements, visibleText);
    if (interactiveElements.count >= 120) {
        return;
    }

    for (UIView *subview in view.subviews ?: @[]) {
        OPAICollectViewTree(subview, window, bundleId, windowIndex, depth + 1,
                elementIndex, interactiveElements, visibleText);
        if (interactiveElements.count >= 120) {
            return;
        }
    }
}

static BOOL OPAIViewCanEvaluateJavaScript(UIView *view) {
    SEL selector = NSSelectorFromString(@"evaluateJavaScript:completionHandler:");
    return view && [view respondsToSelector:selector];
}

static UIView *OPAIFindWebViewInView(UIView *view, NSInteger depth) {
    if (!view || depth > 32 || view.hidden || view.alpha < 0.02) {
        return nil;
    }
    NSString *className = NSStringFromClass([view class]) ?: @"";
    if (OPAIViewCanEvaluateJavaScript(view) ||
            [className isEqualToString:@"_SFWebView"] ||
            [className isEqualToString:@"WKWebView"] ||
            [className isEqualToString:@"WKContentView"]) {
        return view;
    }
    for (UIView *subview in view.subviews ?: @[]) {
        UIView *match = OPAIFindWebViewInView(subview, depth + 1);
        if (match) {
            return match;
        }
    }
    return nil;
}

static UIView *OPAIFindFirstWebView(NSArray<UIWindow *> *windows) {
    for (UIWindow *window in windows ?: @[]) {
        if (!window || window.hidden || window.alpha < 0.02) {
            continue;
        }
        UIView *match = OPAIFindWebViewInView(window, 0);
        if (match) {
            return match;
        }
    }
    return nil;
}

static NSString *OPAIWebDOMQueryFunction(void) {
    return
        @"function opq(){"
        "function clean(v){return (v==null?'':String(v)).replace(/\\s+/g,' ').trim().slice(0,300);}"
        "function visible(el){var r=el.getBoundingClientRect();var s=getComputedStyle(el);"
        "return r.width>=1&&r.height>=1&&s.display!=='none'&&s.visibility!=='hidden'&&s.opacity!=='0';}"
        "function label(el){return clean(el.getAttribute('aria-label')||el.getAttribute('title')||"
        "el.getAttribute('placeholder')||el.innerText||el.value||el.textContent||el.tagName);}"
        "function css(el){var p=[];for(var n=el;n&&n.nodeType===1&&p.length<5;n=n.parentElement){"
        "var part=n.tagName.toLowerCase();if(n.id){part+='#'+n.id;p.unshift(part);break;}"
        "var i=1,s=n;while((s=s.previousElementSibling)!=null){if(s.tagName===n.tagName)i++;}"
        "p.unshift(part+':nth-of-type('+i+')');}return p.join('>');}"
        "var selector='input,textarea,select,button,a,[contenteditable=\"\"],[contenteditable=\"true\"],"
        "[role=\"textbox\"],[role=\"button\"],[tabindex]';"
        "var nodes=Array.prototype.slice.call(document.querySelectorAll(selector)).filter(visible).slice(0,80);"
        "var active=document.activeElement;"
        "var elements=nodes.map(function(el,i){var r=el.getBoundingClientRect();var tag=el.tagName.toLowerCase();"
        "var type=clean(el.getAttribute('type')).toLowerCase();var sensitive=(tag==='input'&&type==='password');"
        "var value=sensitive?'':clean(('value' in el)?el.value:'');"
        "return {index:i,tag:tag,type:type,role:clean(el.getAttribute('role')).toLowerCase(),"
        "label:label(el),value:value,disabled:!!el.disabled,focused:el===active,editable:"
        "(tag==='textarea'||(tag==='input'&&!['button','submit','reset','checkbox','radio','file','image','range','color'].includes(type))||el.isContentEditable||el.getAttribute('role')==='textbox'),"
        "href:clean(el.href),selector:css(el),rect:{x:r.left,y:r.top,width:r.width,height:r.height}};});"
        "var texts=[];function add(t){t=clean(t);if(t&&texts.indexOf(t)<0&&texts.length<40)texts.push(t);}"
        "add(document.title);var walker=document.createTreeWalker(document.body||document.documentElement,"
        "NodeFilter.SHOW_TEXT,{acceptNode:function(n){var t=clean(n.nodeValue);if(!t)return NodeFilter.FILTER_REJECT;"
        "var p=n.parentElement;if(!p||!visible(p))return NodeFilter.FILTER_REJECT;return NodeFilter.FILTER_ACCEPT;}});"
        "var n;while((n=walker.nextNode())&&texts.length<40)add(n.nodeValue);"
        "var vv=window.visualViewport;"
        "return {status:'ok',url:String(location.href),title:clean(document.title),active_index:nodes.indexOf(active),"
        "viewport:{width:window.innerWidth||1,height:window.innerHeight||1,scale:vv?vv.scale:1,"
        "offset_left:vv?vv.offsetLeft:0,offset_top:vv?vv.offsetTop:0},visible_text:texts,elements:elements};}";
}

static NSDictionary *OPAIWebViewEvaluateJSON(UIView *webView, NSString *script, NSTimeInterval timeoutSeconds) {
    if (!OPAIViewCanEvaluateJavaScript(webView)) {
        return @{@"status": @"unavailable", @"reason": @"webview_evaluate_javascript_unavailable"};
    }
    SEL selector = NSSelectorFromString(@"evaluateJavaScript:completionHandler:");
    __block BOOL done = NO;
    __block id rawResult = nil;
    __block NSError *rawError = nil;
    void (^completion)(id, NSError *) = ^(id result, NSError *error) {
        rawResult = result;
        rawError = error;
        done = YES;
    };
    @try {
        typedef void (*EvalSend)(id, SEL, id, id);
        ((EvalSend)objc_msgSend)(webView, selector, script ?: @"", completion);
    } @catch (NSException *exception) {
        return @{
            @"status": @"unavailable",
            @"reason": @"webview_evaluate_exception",
            @"exception_name": exception.name ?: @"",
            @"exception_reason": exception.reason ?: @""
        };
    }
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeoutSeconds > 0.0 ? timeoutSeconds : 0.75];
    while (!done && [deadline timeIntervalSinceNow] > 0.0) {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
    if (!done) {
        return @{@"status": @"unavailable", @"reason": @"webview_evaluate_timeout"};
    }
    if (rawError) {
        return @{
            @"status": @"unavailable",
            @"reason": @"webview_evaluate_error",
            @"error": rawError.localizedDescription ?: @""
        };
    }
    if ([rawResult isKindOfClass:[NSString class]]) {
        NSDictionary *parsed = OPAIDictionaryFromJSONString(rawResult);
        if (parsed.count > 0) {
            return parsed;
        }
    }
    if ([rawResult isKindOfClass:[NSDictionary class]]) {
        return rawResult;
    }
    return @{@"status": @"unavailable", @"reason": @"webview_evaluate_empty_result"};
}

static NSString *OPAIWebDOMDiscoveryScript(void) {
    return [NSString stringWithFormat:@"(function(){%@ return JSON.stringify(opq());})()",
            OPAIWebDOMQueryFunction()];
}

static void OPAIAppendUniqueText(NSMutableArray<NSString *> *visibleText, NSString *text) {
    NSString *clean = OPAIString(text);
    if (clean.length > 0 && visibleText.count < 120 && ![visibleText containsObject:clean]) {
        [visibleText addObject:clean.length <= 300 ? clean : [clean substringToIndex:300]];
    }
}

static NSString *OPAIWebElementKind(NSDictionary *domElement) {
    NSString *tag = [domElement[@"tag"] isKindOfClass:[NSString class]] ? domElement[@"tag"] : @"";
    NSString *type = [domElement[@"type"] isKindOfClass:[NSString class]] ? domElement[@"type"] : @"";
    NSString *role = [domElement[@"role"] isKindOfClass:[NSString class]] ? domElement[@"role"] : @"";
    if ([role isEqualToString:@"textbox"] || [tag isEqualToString:@"textarea"] ||
            ([tag isEqualToString:@"input"] && ![type isEqualToString:@"button"] &&
                    ![type isEqualToString:@"submit"] && ![type isEqualToString:@"reset"])) {
        return @"web_text_field";
    }
    if ([tag isEqualToString:@"button"] || [role isEqualToString:@"button"] ||
            ([tag isEqualToString:@"input"] && ([type isEqualToString:@"button"] ||
                    [type isEqualToString:@"submit"] || [type isEqualToString:@"reset"]))) {
        return @"web_button";
    }
    if ([tag isEqualToString:@"a"]) {
        return @"web_link";
    }
    if ([tag isEqualToString:@"select"]) {
        return @"web_select";
    }
    return @"web_element";
}

static NSArray<NSDictionary *> *OPAIWebDOMElements(NSDictionary *dom,
        CGRect webBounds,
        NSString *bundleId) {
    NSArray *elements = [dom[@"elements"] isKindOfClass:[NSArray class]] ? dom[@"elements"] : @[];
    NSDictionary *viewport = [dom[@"viewport"] isKindOfClass:[NSDictionary class]] ? dom[@"viewport"] : @{};
    double viewportWidth = MAX(1.0, OPAINumberDouble(viewport[@"width"], webBounds.size.width));
    double viewportHeight = MAX(1.0, OPAINumberDouble(viewport[@"height"], webBounds.size.height));
    NSString *safeBundle = OPAISafeFilenameForBundleId(bundleId ?: @"app");
    NSMutableArray<NSDictionary *> *snapshots = [NSMutableArray array];
    NSUInteger index = 0;
    for (id object in elements) {
        if (![object isKindOfClass:[NSDictionary class]] || snapshots.count >= 80) {
            continue;
        }
        NSDictionary *domElement = object;
        NSDictionary *rect = [domElement[@"rect"] isKindOfClass:[NSDictionary class]]
                ? domElement[@"rect"] : @{};
        double x = OPAINumberDouble(rect[@"x"], 0.0);
        double y = OPAINumberDouble(rect[@"y"], 0.0);
        double width = OPAINumberDouble(rect[@"width"], 0.0);
        double height = OPAINumberDouble(rect[@"height"], 0.0);
        if (width < 1.0 || height < 1.0) {
            continue;
        }
        CGRect bounds = CGRectMake(webBounds.origin.x + x * webBounds.size.width / viewportWidth,
                webBounds.origin.y + y * webBounds.size.height / viewportHeight,
                width * webBounds.size.width / viewportWidth,
                height * webBounds.size.height / viewportHeight);
        NSString *label = OPAIString(domElement[@"label"]);
        NSString *value = OPAIString(domElement[@"value"]);
        NSString *selector = OPAIString(domElement[@"selector"]);
        long long domIndex = OPAINumberLongLong(domElement[@"index"], (long long)index);
        NSMutableDictionary *snapshot = [@{
            @"id": [NSString stringWithFormat:@"app-%@-web-%lld", safeBundle, domIndex],
            @"kind": OPAIWebElementKind(domElement),
            @"class": @"DOMElement",
            @"label": label.length <= 300 ? label : [label substringToIndex:300],
            @"bounds": OPAIBoundsArray(bounds),
            @"enabled": @(![domElement[@"disabled"] boolValue]),
            @"focused": @([domElement[@"focused"] boolValue]),
            @"window_id": @0,
            @"source_bundle_id": bundleId ?: @"",
            @"scope": @"web_content_process",
            @"input_scope": @"app_process",
            @"sensitive": @NO,
            @"risk_hint": @"web_content_process",
            @"dom_index": @(domIndex),
            @"tag": OPAIString(domElement[@"tag"]),
            @"input_type": OPAIString(domElement[@"type"])
        } mutableCopy];
        if (value.length > 0) {
            snapshot[@"value"] = value.length <= 300 ? value : [value substringToIndex:300];
        }
        if (selector.length > 0) {
            snapshot[@"view_id"] = selector;
        }
        [snapshots addObject:snapshot];
        index++;
    }
    return snapshots;
}

static NSDictionary *OPAIWebDOMSnapshot(UIView *webView,
        CGRect webBounds,
        NSString *bundleId,
        NSMutableArray<NSString *> *visibleText,
        NSMutableArray<NSDictionary *> *interactiveElements) {
    if (!webView || ![bundleId isEqualToString:@"com.apple.mobilesafari"]) {
        return @{@"status": @"not_applicable"};
    }
    NSDictionary *dom = OPAIWebViewEvaluateJSON(webView, OPAIWebDOMDiscoveryScript(), 0.80);
    if (![dom[@"status"] isEqualToString:@"ok"]) {
        return dom.count > 0 ? dom : @{@"status": @"unavailable", @"reason": @"web_dom_empty"};
    }
    for (id text in ([dom[@"visible_text"] isKindOfClass:[NSArray class]] ? dom[@"visible_text"] : @[])) {
        if ([text isKindOfClass:[NSString class]]) {
            OPAIAppendUniqueText(visibleText, text);
        }
    }
    NSArray<NSDictionary *> *domElements = OPAIWebDOMElements(dom, webBounds, bundleId);
    for (NSDictionary *element in domElements) {
        if (interactiveElements.count >= 120) {
            break;
        }
        [interactiveElements addObject:element];
    }
    return @{
        @"status": @"ok",
        @"provider": @"OpenPhoneAppIntrospector.WebKitDOM",
        @"scope": @"web_content_process",
        @"url": OPAIString(dom[@"url"]),
        @"title": OPAIString(dom[@"title"]),
        @"element_count": @(domElements.count),
        @"text_count": @(([dom[@"visible_text"] isKindOfClass:[NSArray class]]
                ? [dom[@"visible_text"] count] : 0)),
        @"web_view_class": NSStringFromClass([webView class]) ?: @"",
        @"web_view_bounds": OPAIBoundsArray(webBounds)
    };
}

static NSString *OPAIApplicationStateName(UIApplicationState state) {
    switch (state) {
        case UIApplicationStateActive:
            return @"active";
        case UIApplicationStateInactive:
            return @"inactive";
        case UIApplicationStateBackground:
            return @"background";
    }
    return @"unknown";
}

static NSDictionary *OPAIAppSnapshot(void) {
    UIApplication *application = nil;
    @try {
        application = [UIApplication sharedApplication];
    } @catch (__unused NSException *exception) {
        application = nil;
    }
    NSString *bundleId = OPAIEffectiveAppBundleId();
    NSString *processBundleId = OPAIAppBundleId();
    NSString *provider = OPAIProviderName();
    if (!application) {
        return @{
            @"schema": @"openphone.app_ui_state.v1",
            @"status": @"unavailable",
            @"provider": provider,
            @"bundle_id": bundleId,
            @"process_bundle_id": processBundleId,
            @"effective_bundle_id": bundleId,
            @"reason": @"application_unavailable",
            @"timestamp_ms": @(OPAINowMs()),
            @"process_name": NSProcessInfo.processInfo.processName ?: @"",
            @"pid": @(getpid()),
            @"source": OPAIElementScope()
        };
    }

    NSMutableArray<NSDictionary *> *windows = [NSMutableArray array];
    NSMutableArray<NSDictionary *> *interactiveElements = [NSMutableArray array];
    NSMutableArray<NSString *> *visibleText = [NSMutableArray array];
    NSArray<UIWindow *> *applicationWindows = OPAIApplicationWindows(application);
    NSUInteger elementIndex = 0;
    NSInteger windowIndex = 0;
    for (UIWindow *window in applicationWindows) {
        if (!window || window.hidden || window.alpha < 0.02) {
            windowIndex++;
            continue;
        }
        [windows addObject:OPAIWindowSnapshot(window, windowIndex)];
        OPAICollectViewTree(window, window, bundleId, windowIndex, 0,
                &elementIndex, interactiveElements, visibleText);
        windowIndex++;
        if (windows.count >= 16 || interactiveElements.count >= 120) {
            break;
        }
    }

    UIView *webView = OPAIFindFirstWebView(applicationWindows);
    NSDictionary *webDOM = @{@"status": @"not_applicable"};
    if (webView && [bundleId isEqualToString:@"com.apple.mobilesafari"]) {
        UIWindow *webWindow = webView.window ?: applicationWindows.firstObject;
        CGRect webBounds = webWindow
                ? [webView convertRect:webView.bounds toView:webWindow]
                : webView.bounds;
        webDOM = OPAIWebDOMSnapshot(webView, webBounds, bundleId,
                visibleText, interactiveElements);
    }

    NSMutableDictionary *uiTree = [@{
        @"status": @"ok",
        @"provider": provider,
        @"scope": OPAIElementScope(),
        @"bundle_id": bundleId,
        @"process_bundle_id": processBundleId,
        @"effective_bundle_id": bundleId,
        @"window_count": @(windows.count),
        @"element_count": @(interactiveElements.count),
        @"text_count": @(visibleText.count),
        @"windows": windows,
        @"interactive_elements": interactiveElements,
        @"visible_text": visibleText
    } mutableCopy];
    if (webDOM.count > 0 && ![webDOM[@"status"] isEqualToString:@"not_applicable"]) {
        uiTree[@"web_dom"] = webDOM;
    }
    UIApplicationState applicationState = application.applicationState;
    return @{
        @"schema": @"openphone.app_ui_state.v1",
        @"status": @"ok",
        @"provider": provider,
        @"bundle_id": bundleId,
        @"process_bundle_id": processBundleId,
        @"effective_bundle_id": bundleId,
        @"process_name": NSProcessInfo.processInfo.processName ?: @"",
        @"pid": @(getpid()),
        @"timestamp_ms": @(OPAINowMs()),
        @"application_state": @((NSInteger)applicationState),
        @"application_state_name": OPAIApplicationStateName(applicationState),
        @"ui_tree": uiTree,
        @"source": OPAIElementScope()
    };
}

static BOOL OPAIWriteJSONFile(NSString *path, NSDictionary *object) {
    if (path.length == 0 || !object) {
        return NO;
    }
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:object
                                                   options:0
                                                     error:&error];
    if (!data || error) {
        return NO;
    }
    BOOL wrote = [data writeToFile:path atomically:YES];
    if (wrote) {
        chmod(path.UTF8String, 0644);
    }
    return wrote;
}

static BOOL OPAIWriteAll(int fd, NSData *data) {
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger remaining = data.length;
    while (remaining > 0) {
        ssize_t written = write(fd, bytes, remaining);
        if (written > 0) {
            bytes += written;
            remaining -= (NSUInteger)written;
            continue;
        }
        if (written < 0 && errno == EINTR) {
            continue;
        }
        return NO;
    }
    return YES;
}

static NSDictionary *OPAIErrorResponse(NSString *reason) {
    return @{
        @"status": @"unavailable",
        @"provider": @"OpenPhoneAppIntrospector.DaemonClient",
        @"reason": reason ?: @"unknown",
        @"timestamp_ms": @(OPAINowMs()),
        @"source": @"app_process"
    };
}

static NSDictionary *OPAIDaemonRequest(NSDictionary *request) {
    if (!request) {
        return OPAIErrorResponse(@"missing_request");
    }
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:request options:0 error:&error];
    if (!json || error) {
        return OPAIErrorResponse(@"json_encode_failed");
    }
    NSMutableData *payload = [json mutableCopy];
    const uint8_t newline = '\n';
    [payload appendBytes:&newline length:1];

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return OPAIErrorResponse(@"socket_failed");
    }
    struct timeval timeout;
    timeout.tv_sec = 1;
    timeout.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));

    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_port = htons(27631);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    BOOL ok = connect(fd, (struct sockaddr *)&address, sizeof(address)) == 0;
    if (!ok) {
        close(fd);
        return OPAIErrorResponse(@"connect_failed");
    }
    ok = OPAIWriteAll(fd, payload);
    if (ok) {
        shutdown(fd, SHUT_WR);
    }
    NSMutableData *responseData = [NSMutableData data];
    if (ok) {
        char buffer[4096];
        while (responseData.length < (128 * 1024)) {
            ssize_t count = read(fd, buffer, sizeof(buffer));
            if (count > 0) {
                [responseData appendBytes:buffer length:(NSUInteger)count];
                if (memchr(buffer, '\n', (size_t)count) != NULL) {
                    break;
                }
                continue;
            }
            if (count < 0 && errno == EINTR) {
                continue;
            }
            break;
        }
    }
    close(fd);
    if (!ok) {
        return OPAIErrorResponse(@"write_failed");
    }
    if (responseData.length == 0) {
        return OPAIErrorResponse(@"empty_response");
    }
    id response = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:nil];
    if (![response isKindOfClass:[NSDictionary class]]) {
        return OPAIErrorResponse(@"json_decode_failed");
    }
    return response;
}

static BOOL OPAIPublishSnapshotToDaemon(NSDictionary *snapshot) {
    if (!snapshot) {
        return NO;
    }
    NSDictionary *response = OPAIDaemonRequest(@{
        @"command": @"app_ui_publish",
        @"transport": @"app_process_tcp_loopback",
        @"state": snapshot
    });
    return [response[@"status"] isEqualToString:@"ok"];
}

static BOOL OPAIWebContentSnapshotReadyForDaemon(NSDictionary *snapshot) {
    if (!OPAIIsWebContentProcess()) {
        return YES;
    }
    if (![snapshot[@"status"] isEqualToString:@"ok"]) {
        return NO;
    }
    NSDictionary *uiTree = [snapshot[@"ui_tree"] isKindOfClass:[NSDictionary class]]
            ? snapshot[@"ui_tree"] : @{};
    if (![uiTree[@"status"] isEqualToString:@"ok"]) {
        return NO;
    }
    long long elementCount = [uiTree[@"element_count"] respondsToSelector:@selector(longLongValue)]
            ? [uiTree[@"element_count"] longLongValue] : 0;
    long long textCount = [uiTree[@"text_count"] respondsToSelector:@selector(longLongValue)]
            ? [uiTree[@"text_count"] longLongValue] : 0;
    return elementCount > 0 || textCount > 0;
}

static NSString *OPAIStorageBundleIdForSnapshot(NSDictionary *snapshot) {
    if (OPAIIsWebContentProcess() && !OPAIWebContentSnapshotReadyForDaemon(snapshot)) {
        return [NSString stringWithFormat:@"%@.%d", OPAIAppBundleId(), getpid()];
    }
    NSString *bundleId = [snapshot[@"bundle_id"] isKindOfClass:[NSString class]]
            ? snapshot[@"bundle_id"] : OPAIEffectiveAppBundleId();
    return bundleId.length > 0 ? bundleId : OPAIAppBundleId();
}

static void OPAIPublishAppState(void) {
    @autoreleasepool {
        [[NSFileManager defaultManager] createDirectoryAtPath:OPAIStorePath
                                  withIntermediateDirectories:YES
                                                   attributes:@{NSFilePosixPermissions: @0755}
                                                        error:nil];
        [[NSFileManager defaultManager] createDirectoryAtPath:OPAIAppUIDir
                                  withIntermediateDirectories:YES
                                                   attributes:@{NSFilePosixPermissions: @0755}
                                                        error:nil];
        @try {
            NSDictionary *snapshot = OPAIAppSnapshot();
            if (OPAIWebContentSnapshotReadyForDaemon(snapshot) &&
                    OPAIPublishSnapshotToDaemon(snapshot)) {
                return;
            }
            NSString *bundleId = OPAIStorageBundleIdForSnapshot(snapshot);
            NSString *filename = [OPAISafeFilenameForBundleId(bundleId)
                    stringByAppendingPathExtension:@"json"];
            NSString *path = [OPAIAppUIDir stringByAppendingPathComponent:filename];
            if (!OPAIWriteJSONFile(path, snapshot)) {
                OPAILog(@"state write failed bundle=%@ path=%@", bundleId ?: @"", path ?: @"");
            }
        } @catch (NSException *exception) {
            OPAILog(@"state publish exception name=%@ reason=%@",
                    exception.name ?: @"", exception.reason ?: @"");
        }
    }
}

static void OPAIPublishAppStateOnMain(void) {
    if ([NSThread isMainThread]) {
        OPAIPublishAppState();
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            OPAIPublishAppState();
        });
    }
}

static BOOL OPAIDoubleForKey(NSDictionary *dictionary, NSString *key, double *outValue) {
    id value = dictionary[key];
    if ([value respondsToSelector:@selector(doubleValue)]) {
        if (outValue) {
            *outValue = [value doubleValue];
        }
        return YES;
    }
    return NO;
}

static long long OPAILongLongForKey(NSDictionary *dictionary,
        NSString *key,
        long long defaultValue,
        long long minValue,
        long long maxValue) {
    id value = dictionary[key];
    long long result = [value respondsToSelector:@selector(longLongValue)]
            ? [value longLongValue] : defaultValue;
    if (result < minValue) {
        result = minValue;
    }
    if (result > maxValue) {
        result = maxValue;
    }
    return result;
}

static CGPoint OPAINormalizeInputPoint(double x, double y) {
    CGFloat px = (CGFloat)x;
    CGFloat py = (CGFloat)y;
    UIScreen *screen = [UIScreen mainScreen];
    CGFloat scale = screen.scale > 0.0 ? screen.scale : 1.0;
    CGRect bounds = screen.bounds;
    if ((px > CGRectGetWidth(bounds) * 1.5 || py > CGRectGetHeight(bounds) * 1.5) &&
            scale > 1.0) {
        px = px / scale;
        py = py / scale;
    }
    return CGPointMake(px, py);
}

static UIView *OPAIFindElementInView(UIView *view,
        UIWindow *window,
        NSString *bundleId,
        NSInteger windowIndex,
        NSInteger depth,
        NSUInteger *elementIndex,
        NSString *wantedElementId,
        NSDictionary **outElement) {
    if (!view || depth > 32 || !elementIndex || wantedElementId.length == 0) {
        return nil;
    }
    if (view.hidden || view.alpha < 0.02) {
        return nil;
    }
    CGRect bounds = [view convertRect:view.bounds toView:window];
    if (CGRectIsEmpty(bounds) || bounds.size.width < 1.0 || bounds.size.height < 1.0) {
        return nil;
    }
    BOOL sensitive = OPAIViewIsSensitive(view);
    NSString *label = OPAIViewLabel(view);
    NSString *identifier = OPAIString(view.accessibilityIdentifier);
    BOOL interactive = OPAIViewLooksInteractive(view, label, identifier);
    BOOL editableText = [view isKindOfClass:[UITextField class]] ||
            [view isKindOfClass:[UITextView class]] ||
            [view isKindOfClass:[UISearchBar class]];
    if (interactive && (label.length > 0 || identifier.length > 0 || editableText)) {
        NSDictionary *element = OPAIElementSnapshotForView(view, bundleId, windowIndex,
                *elementIndex, bounds, label, sensitive, identifier);
        (*elementIndex)++;
        if ([element[@"id"] isEqualToString:wantedElementId]) {
            if (outElement) {
                *outElement = element;
            }
            return view;
        }
    }
    for (id child in OPAIAccessibilityChildrenForView(view)) {
        if ([child isKindOfClass:[UIView class]]) {
            continue;
        }
        NSString *childLabel = OPAIAccessibilityStringValue(child, @selector(accessibilityLabel));
        NSString *childValue = OPAIAccessibilityStringValue(child, @selector(accessibilityValue));
        if (childLabel.length == 0 && childValue.length == 0) {
            continue;
        }
        CGRect frame = OPAIAccessibilityFrameValue(child);
        if (CGRectIsEmpty(frame) || frame.size.width < 1.0 || frame.size.height < 1.0) {
            continue;
        }
        NSDictionary *element = OPAIElementSnapshotForAccessibilityObject(child, bundleId,
                windowIndex, *elementIndex, frame);
        (*elementIndex)++;
        if ([element[@"id"] isEqualToString:wantedElementId]) {
            if (outElement) {
                *outElement = element;
            }
            return view;
        }
        if (*elementIndex >= 120) {
            return nil;
        }
    }
    for (UIView *subview in view.subviews ?: @[]) {
        UIView *match = OPAIFindElementInView(subview, window, bundleId, windowIndex,
                depth + 1, elementIndex, wantedElementId, outElement);
        if (match) {
            return match;
        }
        if (*elementIndex >= 120) {
            return nil;
        }
    }
    return nil;
}

static UIView *OPAIFindElementById(NSString *elementId,
        NSDictionary **outElement,
        UIWindow **outWindow) {
    UIApplication *application = nil;
    @try {
        application = [UIApplication sharedApplication];
    } @catch (__unused NSException *exception) {
        application = nil;
    }
    if (!application || elementId.length == 0) {
        return nil;
    }
    NSString *bundleId = OPAIEffectiveAppBundleId();
    NSUInteger elementIndex = 0;
    NSInteger windowIndex = 0;
    for (UIWindow *window in OPAIApplicationWindows(application)) {
        if (!window || window.hidden || window.alpha < 0.02) {
            windowIndex++;
            continue;
        }
        UIView *match = OPAIFindElementInView(window, window, bundleId, windowIndex, 0,
                &elementIndex, elementId, outElement);
        if (match) {
            if (outWindow) {
                *outWindow = window;
            }
            return match;
        }
        windowIndex++;
        if (elementIndex >= 120) {
            break;
        }
    }
    return nil;
}

static NSInteger OPAIWindowIndexForWindow(UIWindow *targetWindow, NSArray<UIWindow *> *windows) {
    NSInteger index = 0;
    for (UIWindow *window in windows ?: @[]) {
        if (window == targetWindow) {
            return index;
        }
        index++;
    }
    return 0;
}

static NSDictionary *OPAIHitElementSummary(UIView *view, UIWindow *window) {
    if (!view || !window) {
        return @{};
    }
    UIApplication *application = nil;
    @try {
        application = [UIApplication sharedApplication];
    } @catch (__unused NSException *exception) {
        application = nil;
    }
    NSArray<UIWindow *> *windows = application ? OPAIApplicationWindows(application) : @[];
    NSInteger windowIndex = OPAIWindowIndexForWindow(window, windows);
    NSString *bundleId = OPAIEffectiveAppBundleId();
    BOOL sensitive = OPAIViewIsSensitive(view);
    NSString *label = OPAIViewLabel(view);
    NSString *identifier = OPAIString(view.accessibilityIdentifier);
    CGRect bounds = [view convertRect:view.bounds toView:window];
    NSMutableDictionary *summary = [OPAIElementSnapshotForView(view, bundleId, windowIndex,
            0, bounds, label, sensitive, identifier) mutableCopy];
    summary[@"id"] = [NSString stringWithFormat:@"app-%@-hit-%p",
            OPAISafeFilenameForBundleId(bundleId), view];
    return summary;
}

static UIView *OPAIHitTestView(CGPoint point,
        UIWindow **outWindow,
        NSDictionary **outElement) {
    UIApplication *application = nil;
    @try {
        application = [UIApplication sharedApplication];
    } @catch (__unused NSException *exception) {
        application = nil;
    }
    if (!application) {
        return nil;
    }
    NSArray<UIWindow *> *windows = [OPAIApplicationWindows(application) sortedArrayUsingComparator:
            ^NSComparisonResult(UIWindow *a, UIWindow *b) {
        if (a.windowLevel > b.windowLevel) {
            return NSOrderedAscending;
        }
        if (a.windowLevel < b.windowLevel) {
            return NSOrderedDescending;
        }
        return NSOrderedSame;
    }];
    for (UIWindow *window in windows ?: @[]) {
        if (!window || window.hidden || window.alpha < 0.02 || !window.userInteractionEnabled) {
            continue;
        }
        CGPoint localPoint = [window convertPoint:point fromWindow:nil];
        if (![window pointInside:localPoint withEvent:nil]) {
            continue;
        }
        UIView *hit = [window hitTest:localPoint withEvent:nil];
        if (hit) {
            if (outWindow) {
                *outWindow = window;
            }
            if (outElement) {
                *outElement = OPAIHitElementSummary(hit, window);
            }
            return hit;
        }
    }
    return nil;
}

static NSDictionary *OPAIInputResponse(NSString *status,
        NSString *reason,
        NSString *actionType,
        NSDictionary *target,
        NSDictionary *extra) {
    NSMutableDictionary *response = [@{
        @"status": status ?: @"unavailable",
        @"provider": OPAIInputProviderName(),
        @"action_type": actionType ?: @"",
        @"source": OPAIElementScope(),
        @"timestamp_ms": @(OPAINowMs())
    } mutableCopy];
    if (reason.length > 0) {
        response[@"reason"] = reason;
    }
    if (target) {
        response[@"target"] = target;
    }
    for (NSString *key in extra ?: @{}) {
        id value = extra[key];
        if (value) {
            response[key] = value;
        }
    }
    return response;
}

static NSArray<NSString *> *OPAIMethodCandidatesForClass(Class cls) {
    if (!cls) {
        return @[];
    }
    NSArray<NSString *> *needles = @[
        @"activ", @"address", @"bar", @"begin", @"capsule", @"edit",
        @"focus", @"location", @"navig", @"select", @"text", @"title", @"url"
    ];
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    if (!methods) {
        return @[];
    }
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    for (unsigned int i = 0; i < count && candidates.count < 40; i++) {
        SEL selector = method_getName(methods[i]);
        const char *name = selector ? sel_getName(selector) : NULL;
        if (!name) {
            continue;
        }
        NSString *selectorName = [NSString stringWithUTF8String:name] ?: @"";
        NSString *lower = selectorName.lowercaseString;
        for (NSString *needle in needles) {
            if ([lower containsString:needle]) {
                [candidates addObject:selectorName];
                break;
            }
        }
    }
    free(methods);
    return candidates;
}

static NSArray<NSDictionary *> *OPAIDiagnosticsForViewAncestors(UIView *view) {
    NSMutableArray<NSDictionary *> *diagnostics = [NSMutableArray array];
    NSInteger depth = 0;
    for (UIView *cursor = view; cursor && depth < 8; cursor = cursor.superview, depth++) {
        Class cls = [cursor class];
        NSArray<NSString *> *methods = OPAIMethodCandidatesForClass(cls);
        if (methods.count > 0) {
            [diagnostics addObject:@{
                @"depth": @(depth),
                @"class": NSStringFromClass(cls) ?: @"",
                @"methods": methods
            }];
        } else {
            [diagnostics addObject:@{
                @"depth": @(depth),
                @"class": NSStringFromClass(cls) ?: @"",
                @"methods": @[]
            }];
        }
    }
    return diagnostics;
}

static UIView *OPAIEditableTextViewForView(UIView *view) {
    if (!view) {
        return nil;
    }
    if ([view isKindOfClass:[UITextField class]] ||
            [view isKindOfClass:[UITextView class]]) {
        return view;
    }
    if ([view isKindOfClass:[UISearchBar class]]) {
        @try {
            UITextField *field = ((UISearchBar *)view).searchTextField;
            if (field) {
                return field;
            }
        } @catch (__unused NSException *exception) {
        }
    }
    if ([OPAIAppBundleId() isEqualToString:@"com.apple.mobilesafari"] &&
            [NSStringFromClass([view class]) isEqualToString:@"SFCapsuleNavigationBar"]) {
        SEL selector = NSSelectorFromString(@"textField");
        if ([view respondsToSelector:selector]) {
            id value = nil;
            @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                value = [view performSelector:selector];
#pragma clang diagnostic pop
            } @catch (__unused NSException *exception) {
                value = nil;
            }
            if ([value isKindOfClass:[UITextField class]] ||
                    [value isKindOfClass:[UITextView class]]) {
                return (UIView *)value;
            }
            if ([value isKindOfClass:[UIView class]]) {
                UIView *valueView = (UIView *)value;
                if ([valueView conformsToProtocol:@protocol(UITextInput)] ||
                        [valueView conformsToProtocol:@protocol(UIKeyInput)] ||
                        [valueView canBecomeFirstResponder]) {
                    return valueView;
                }
            }
            if ([value isKindOfClass:[UIView class]] && value != view) {
                UIView *match = OPAIEditableTextViewForView((UIView *)value);
                if (match) {
                    return match;
                }
            }
        }
    }
    for (UIView *subview in view.subviews ?: @[]) {
        UIView *match = OPAIEditableTextViewForView(subview);
        if (match) {
            return match;
        }
    }
    return nil;
}

static UIView *OPAIEditableTextViewForViewOrAncestors(UIView *view) {
    NSInteger depth = 0;
    for (UIView *cursor = view; cursor && depth < 10; cursor = cursor.superview, depth++) {
        UIView *editable = OPAIEditableTextViewForView(cursor);
        if (editable) {
            return editable;
        }
    }
    return nil;
}

static BOOL OPAIInvokeZeroArgumentSelector(id target,
        NSString *selectorName,
        NSString **outStatus) {
    SEL selector = NSSelectorFromString(selectorName ?: @"");
    if (!target || !selector || ![target respondsToSelector:selector]) {
        if (outStatus) {
            *outStatus = @"missing";
        }
        return NO;
    }
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 2) {
        if (outStatus) {
            *outStatus = @"unsupported_signature";
        }
        return NO;
    }
    @try {
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.target = target;
        invocation.selector = selector;
        [invocation invoke];
        if (outStatus) {
            *outStatus = @"invoked";
        }
        return YES;
    } @catch (__unused NSException *exception) {
        if (outStatus) {
            *outStatus = @"exception";
        }
        return NO;
    }
}

static BOOL OPAIInvokeBooleanArgumentSelector(id target,
        NSString *selectorName,
        BOOL value,
        NSString **outStatus) {
    SEL selector = NSSelectorFromString(selectorName ?: @"");
    if (!target || !selector || ![target respondsToSelector:selector]) {
        if (outStatus) {
            *outStatus = @"missing";
        }
        return NO;
    }
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != 3) {
        if (outStatus) {
            *outStatus = @"unsupported_signature";
        }
        return NO;
    }
    @try {
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.target = target;
        invocation.selector = selector;
        BOOL argument = value;
        [invocation setArgument:&argument atIndex:2];
        [invocation invoke];
        if (outStatus) {
            *outStatus = @"invoked";
        }
        return YES;
    } @catch (__unused NSException *exception) {
        if (outStatus) {
            *outStatus = @"exception";
        }
        return NO;
    }
}

static NSDictionary *OPAIActivateSafariAddressView(UIView *view,
        NSDictionary *target,
        NSString *actionType,
        long long durationMs,
        NSArray<NSString *> *priorAttempts) {
    if (![OPAIAppBundleId() isEqualToString:@"com.apple.mobilesafari"] || !view) {
        return nil;
    }
    NSMutableArray<NSString *> *attempts = [NSMutableArray arrayWithArray:priorAttempts ?: @[]];
    BOOL sawAddressCapsule = NO;
    BOOL invokedPrivateSelector = NO;
    for (UIView *cursor = view; cursor && attempts.count < 80; cursor = cursor.superview) {
        NSString *className = NSStringFromClass([cursor class]) ?: @"";
        if ([className isEqualToString:@"SFUnifiedTabBarItemTitleContainerView"]) {
            sawAddressCapsule = YES;
            NSString *status = nil;
            if (OPAIInvokeZeroArgumentSelector(cursor, @"beginTransitioningSearchField", &status)) {
                invokedPrivateSelector = YES;
            }
            [attempts addObject:[NSString stringWithFormat:@"%@.beginTransitioningSearchField:%@",
                    className, status ?: @"unknown"]];
        } else if ([className isEqualToString:@"SFCapsuleNavigationBar"] ||
                [className isEqualToString:@"SFCapsuleView"]) {
            sawAddressCapsule = YES;
            NSString *status = nil;
            if (OPAIInvokeBooleanArgumentSelector(cursor, @"setSelected:", YES, &status)) {
                invokedPrivateSelector = YES;
            }
            [attempts addObject:[NSString stringWithFormat:@"%@.setSelected:YES:%@",
                    className, status ?: @"unknown"]];
        } else if ([className isEqualToString:@"SFCapsuleCollectionView"]) {
            sawAddressCapsule = YES;
            NSString *status = nil;
            if (OPAIInvokeZeroArgumentSelector(cursor, @"_tapToShowBarBottomRegion", &status)) {
                invokedPrivateSelector = YES;
            }
            [attempts addObject:[NSString stringWithFormat:@"%@._tapToShowBarBottomRegion:%@",
                    className, status ?: @"unknown"]];
        }
    }
    if (!sawAddressCapsule) {
        return nil;
    }
    if (invokedPrivateSelector) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.10]];
    }

    UIView *editable = OPAIEditableTextViewForViewOrAncestors(view);
    if (!editable) {
        return OPAIInputResponse(@"unavailable", @"safari_address_textfield_not_found",
                actionType, target, @{
            @"activation_method": invokedPrivateSelector
                    ? @"safari_address_private_focus_probe" : @"safari_address_focus_probe",
            @"activated_class": NSStringFromClass([view class]) ?: @"",
            @"duration_ms": @(durationMs),
            @"attempts": attempts,
            @"diagnostics": @{
                @"view_ancestors": OPAIDiagnosticsForViewAncestors(view)
            }
        });
    }
    if (OPAIViewIsSensitive(editable)) {
        return OPAIInputResponse(@"unavailable", @"sensitive_text_input",
                actionType, target, @{@"attempts": attempts});
    }
    if ([editable canBecomeFirstResponder]) {
        BOOL becameFirstResponder = [editable becomeFirstResponder];
        if (becameFirstResponder || editable.isFirstResponder) {
            return OPAIInputResponse(@"ok", nil, actionType, target, @{
                @"activation_method": @"safari_address_textfield_becomeFirstResponder",
                @"activated_class": NSStringFromClass([editable class]) ?: @"",
                @"duration_ms": @(durationMs),
                @"attempts": attempts
            });
        }
        [attempts addObject:[NSString stringWithFormat:@"%@.becomeFirstResponder:false",
                NSStringFromClass([editable class]) ?: @"UIView"]];
    }
    return OPAIInputResponse(@"unavailable", @"safari_address_focus_failed",
            actionType, target, @{
        @"activation_method": invokedPrivateSelector
                ? @"safari_address_private_focus_probe" : @"safari_address_focus_probe",
        @"activated_class": NSStringFromClass([editable class]) ?: @"",
        @"duration_ms": @(durationMs),
        @"attempts": attempts
    });
}

static UIView *OPAIFindFirstResponderInView(UIView *view) {
    if (!view) {
        return nil;
    }
    if (view.isFirstResponder) {
        return view;
    }
    for (UIView *subview in view.subviews ?: @[]) {
        UIView *match = OPAIFindFirstResponderInView(subview);
        if (match) {
            return match;
        }
    }
    return nil;
}

static UIView *OPAIFindFirstResponder(void) {
    UIApplication *application = nil;
    @try {
        application = [UIApplication sharedApplication];
    } @catch (__unused NSException *exception) {
        application = nil;
    }
    if (!application) {
        return nil;
    }
    for (UIWindow *window in OPAIApplicationWindows(application)) {
        UIView *match = OPAIFindFirstResponderInView(window);
        if (match) {
            return match;
        }
    }
    return nil;
}

static NSString *OPAIEditableTextLength(UIView *view) {
    NSString *text = nil;
    if ([view isKindOfClass:[UITextField class]]) {
        text = ((UITextField *)view).text;
    } else if ([view isKindOfClass:[UITextView class]]) {
        text = ((UITextView *)view).text;
    }
    return [NSString stringWithFormat:@"%lu", (unsigned long)(text.length)];
}

static UITableViewCell *OPAITabularCellForView(UIView *view) {
    for (UIView *cursor = view; cursor; cursor = cursor.superview) {
        if ([cursor isKindOfClass:[UITableViewCell class]]) {
            return (UITableViewCell *)cursor;
        }
    }
    return nil;
}

static UITableView *OPAITabularSuperviewForCell(UITableViewCell *cell) {
    for (UIView *cursor = cell.superview; cursor; cursor = cursor.superview) {
        if ([cursor isKindOfClass:[UITableView class]]) {
            return (UITableView *)cursor;
        }
    }
    return nil;
}

static UICollectionViewCell *OPAICollectionCellForView(UIView *view) {
    for (UIView *cursor = view; cursor; cursor = cursor.superview) {
        if ([cursor isKindOfClass:[UICollectionViewCell class]]) {
            return (UICollectionViewCell *)cursor;
        }
    }
    return nil;
}

static UICollectionView *OPAICollectionSuperviewForCell(UICollectionViewCell *cell) {
    for (UIView *cursor = cell.superview; cursor; cursor = cursor.superview) {
        if ([cursor isKindOfClass:[UICollectionView class]]) {
            return (UICollectionView *)cursor;
        }
    }
    return nil;
}

static NSDictionary *OPAIActivateTableCell(UIView *view) {
    UITableViewCell *cell = OPAITabularCellForView(view);
    UITableView *tableView = cell ? OPAITabularSuperviewForCell(cell) : nil;
    NSIndexPath *indexPath = (tableView && cell) ? [tableView indexPathForCell:cell] : nil;
    if (!tableView || !indexPath) {
        return nil;
    }
    [tableView selectRowAtIndexPath:indexPath animated:NO scrollPosition:UITableViewScrollPositionNone];
    id<UITableViewDelegate> delegate = tableView.delegate;
    SEL selector = @selector(tableView:didSelectRowAtIndexPath:);
    if ([delegate respondsToSelector:selector]) {
        [delegate tableView:tableView didSelectRowAtIndexPath:indexPath];
        return @{
            @"status": @"ok",
            @"activation_method": @"uitableview_delegate_did_select",
            @"index_path": [NSString stringWithFormat:@"%ld.%ld",
                    (long)indexPath.section, (long)indexPath.row]
        };
    }
    return @{
        @"status": @"unavailable",
        @"reason": @"uitableview_delegate_unavailable",
        @"activation_method": @"uitableview_select_only",
        @"index_path": [NSString stringWithFormat:@"%ld.%ld",
                (long)indexPath.section, (long)indexPath.row]
    };
}

static NSDictionary *OPAIActivateCollectionCell(UIView *view) {
    UICollectionViewCell *cell = OPAICollectionCellForView(view);
    UICollectionView *collectionView = cell ? OPAICollectionSuperviewForCell(cell) : nil;
    NSIndexPath *indexPath = (collectionView && cell) ? [collectionView indexPathForCell:cell] : nil;
    if (!collectionView || !indexPath) {
        return nil;
    }
    [collectionView selectItemAtIndexPath:indexPath
                                 animated:NO
                           scrollPosition:UICollectionViewScrollPositionNone];
    id<UICollectionViewDelegate> delegate = collectionView.delegate;
    SEL selector = @selector(collectionView:didSelectItemAtIndexPath:);
    if ([delegate respondsToSelector:selector]) {
        [delegate collectionView:collectionView didSelectItemAtIndexPath:indexPath];
        return @{
            @"status": @"ok",
            @"activation_method": @"uicollectionview_delegate_did_select",
            @"index_path": [NSString stringWithFormat:@"%ld.%ld",
                    (long)indexPath.section, (long)indexPath.item]
        };
    }
    return @{
        @"status": @"unavailable",
        @"reason": @"uicollectionview_delegate_unavailable",
        @"activation_method": @"uicollectionview_select_only",
        @"index_path": [NSString stringWithFormat:@"%ld.%ld",
                (long)indexPath.section, (long)indexPath.item]
    };
}

static NSDictionary *OPAIActivateView(UIView *view,
        NSDictionary *target,
        NSString *actionType,
        long long durationMs) {
    if (!view) {
        return OPAIInputResponse(@"unavailable", @"target_view_missing",
                actionType, target, nil);
    }
    NSMutableArray<NSString *> *attempts = [NSMutableArray array];
    NSDictionary *safariAddressActivation = OPAIActivateSafariAddressView(view,
            target, actionType, durationMs, attempts);
    if (safariAddressActivation) {
        return safariAddressActivation;
    }
    NSInteger depth = 0;
    for (UIView *cursor = view; cursor && depth < 10; cursor = cursor.superview, depth++) {
        if (cursor.hidden || cursor.alpha < 0.02) {
            [attempts addObject:@"hidden_or_transparent"];
            continue;
        }
        @try {
            if ([cursor respondsToSelector:@selector(accessibilityActivate)] &&
                    [cursor accessibilityActivate]) {
                return OPAIInputResponse(@"ok", nil, actionType, target, @{
                    @"activation_method": @"accessibilityActivate",
                    @"activated_class": NSStringFromClass([cursor class]) ?: @"",
                    @"duration_ms": @(durationMs),
                    @"attempts": attempts
                });
            }
            [attempts addObject:[NSString stringWithFormat:@"%@.accessibilityActivate:false",
                    NSStringFromClass([cursor class]) ?: @"UIView"]];
        } @catch (NSException *exception) {
            [attempts addObject:[NSString stringWithFormat:@"%@.accessibilityActivate:exception",
                    NSStringFromClass([cursor class]) ?: @"UIView"]];
        }

        UIView *editable = OPAIEditableTextViewForView(cursor);
        if (editable) {
            if (OPAIViewIsSensitive(editable)) {
                return OPAIInputResponse(@"unavailable", @"sensitive_text_input",
                        actionType, target, @{@"attempts": attempts});
            }
            if ([editable canBecomeFirstResponder]) {
                [editable becomeFirstResponder];
                return OPAIInputResponse(@"ok", nil, actionType, target, @{
                    @"activation_method": @"becomeFirstResponder",
                    @"activated_class": NSStringFromClass([editable class]) ?: @"",
                    @"duration_ms": @(durationMs),
                    @"attempts": attempts
                });
            }
            [attempts addObject:[NSString stringWithFormat:@"%@.becomeFirstResponder:false",
                    NSStringFromClass([editable class]) ?: @"UIView"]];
        }

        if ([cursor isKindOfClass:[UISwitch class]]) {
            UISwitch *toggle = (UISwitch *)cursor;
            [toggle setOn:!toggle.on animated:YES];
            [toggle sendActionsForControlEvents:UIControlEventValueChanged];
            return OPAIInputResponse(@"ok", nil, actionType, target, @{
                @"activation_method": @"uiswitch_toggle",
                @"activated_class": NSStringFromClass([cursor class]) ?: @"",
                @"duration_ms": @(durationMs),
                @"attempts": attempts
            });
        }
        if ([cursor isKindOfClass:[UIControl class]]) {
            UIControl *control = (UIControl *)cursor;
            if (!control.enabled) {
                return OPAIInputResponse(@"unavailable", @"control_disabled",
                        actionType, target, @{@"attempts": attempts});
            }
            [control sendActionsForControlEvents:UIControlEventTouchUpInside];
            [control sendActionsForControlEvents:UIControlEventPrimaryActionTriggered];
            return OPAIInputResponse(@"unavailable", @"uicontrol_send_actions_unverified",
                    actionType, target, @{
                @"activation_method": @"uicontrol_send_actions",
                @"activated_class": NSStringFromClass([cursor class]) ?: @"",
                @"duration_ms": @(durationMs),
                @"attempts": attempts,
                @"diagnostics": @{
                    @"view_ancestors": OPAIDiagnosticsForViewAncestors(view)
                }
            });
        }

        NSDictionary *tableActivation = OPAIActivateTableCell(cursor);
        if ([tableActivation[@"status"] isEqualToString:@"ok"]) {
            NSMutableDictionary *extra = [tableActivation mutableCopy];
            extra[@"activated_class"] = NSStringFromClass([cursor class]) ?: @"";
            extra[@"duration_ms"] = @(durationMs);
            extra[@"attempts"] = attempts;
            return OPAIInputResponse(@"ok", nil, actionType, target, extra);
        }

        NSDictionary *collectionActivation = OPAIActivateCollectionCell(cursor);
        if ([collectionActivation[@"status"] isEqualToString:@"ok"]) {
            NSMutableDictionary *extra = [collectionActivation mutableCopy];
            extra[@"activated_class"] = NSStringFromClass([cursor class]) ?: @"";
            extra[@"duration_ms"] = @(durationMs);
            extra[@"attempts"] = attempts;
            return OPAIInputResponse(@"ok", nil, actionType, target, extra);
        }
    }
    return OPAIInputResponse(@"unavailable", @"activation_unhandled",
            actionType, target, @{@"attempts": attempts});
}

static NSDictionary *OPAITypeTextIntoView(UIView *view,
        NSDictionary *target,
        NSString *text,
        NSString *actionType) {
    if (!view) {
        return OPAIInputResponse(@"unavailable", @"target_view_missing",
                actionType, target, nil);
    }
    UIView *editable = OPAIEditableTextViewForViewOrAncestors(view);
    if (!editable) {
        return OPAIInputResponse(@"unavailable", @"editable_text_input_not_found",
                actionType, target, @{
                    @"target_class": NSStringFromClass([view class]) ?: @""
                });
    }
    if (OPAIViewIsSensitive(editable)) {
        return OPAIInputResponse(@"unavailable", @"sensitive_text_input",
                actionType, target, @{
                    @"target_class": NSStringFromClass([editable class]) ?: @""
                });
    }
    BOOL becameFirstResponder = NO;
    if (![editable isFirstResponder] && [editable canBecomeFirstResponder]) {
        becameFirstResponder = [editable becomeFirstResponder];
    }
    if (![editable isFirstResponder] && !becameFirstResponder) {
        return OPAIInputResponse(@"unavailable", @"text_input_focus_failed",
                actionType, target, @{
                    @"target_class": NSStringFromClass([editable class]) ?: @""
                });
    }

    NSString *beforeLength = OPAIEditableTextLength(editable);
    @try {
        if ([editable conformsToProtocol:@protocol(UITextInput)]) {
            id<UITextInput> input = (id<UITextInput>)editable;
            UITextRange *range = input.selectedTextRange;
            if (range) {
                [input replaceRange:range withText:text ?: @""];
            } else if ([editable conformsToProtocol:@protocol(UIKeyInput)]) {
                [(id<UIKeyInput>)editable insertText:text ?: @""];
            } else {
                return OPAIInputResponse(@"unavailable", @"text_input_selection_unavailable",
                        actionType, target, @{
                            @"target_class": NSStringFromClass([editable class]) ?: @""
                        });
            }
        } else if ([editable conformsToProtocol:@protocol(UIKeyInput)]) {
            [(id<UIKeyInput>)editable insertText:text ?: @""];
        } else {
            return OPAIInputResponse(@"unavailable", @"text_input_protocol_unavailable",
                    actionType, target, @{
                        @"target_class": NSStringFromClass([editable class]) ?: @""
                    });
        }
    } @catch (NSException *exception) {
        return OPAIInputResponse(@"unavailable", @"type_text_exception",
                actionType, target, @{
                    @"exception_name": exception.name ?: @"",
                    @"exception_reason": exception.reason ?: @"",
                    @"target_class": NSStringFromClass([editable class]) ?: @""
                });
    }
    if ([editable isKindOfClass:[UITextField class]]) {
        [(UITextField *)editable sendActionsForControlEvents:UIControlEventEditingChanged];
    } else if ([editable isKindOfClass:[UITextView class]]) {
        UITextView *textView = (UITextView *)editable;
        [[NSNotificationCenter defaultCenter] postNotificationName:UITextViewTextDidChangeNotification
                                                            object:textView];
        id<UITextViewDelegate> delegate = textView.delegate;
        if ([delegate respondsToSelector:@selector(textViewDidChange:)]) {
            [delegate textViewDidChange:textView];
        }
    }
    NSString *afterLength = OPAIEditableTextLength(editable);
    long long beforeLen = [beforeLength longLongValue];
    long long afterLen = [afterLength longLongValue];
    // Verify the insert actually landed: some balloon/compose views accept the
    // replaceRange/insertText call without applying it (no first responder, an
    // input delegate that rejects the edit, etc.) and would otherwise report a
    // false success for text that never entered the field. Require the content
    // length to have grown by the inserted text before trusting it.
    NSUInteger insertedLength = (text ?: @"").length;
    if (insertedLength > 0 && afterLen <= beforeLen) {
        return OPAIInputResponse(@"unavailable", @"text_input_not_applied",
                actionType, target, @{
                    @"activation_method": @"text_input_insert",
                    @"target_class": NSStringFromClass([editable class]) ?: @"",
                    @"became_first_responder": @(becameFirstResponder),
                    @"text_length": @(insertedLength),
                    @"before_text_length": @(beforeLen),
                    @"after_text_length": @(afterLen)
                });
    }
    return OPAIInputResponse(@"ok", nil, actionType, target, @{
        @"activation_method": @"text_input_insert",
        @"target_class": NSStringFromClass([editable class]) ?: @"",
        @"became_first_responder": @(becameFirstResponder),
        @"text_length": @(insertedLength),
        @"before_text_length": @(beforeLen),
        @"after_text_length": @(afterLen)
    });
}

static UIView *OPAISafariWebViewForInput(void) {
    if (![OPAIEffectiveAppBundleId() isEqualToString:@"com.apple.mobilesafari"]) {
        return nil;
    }
    UIApplication *application = nil;
    @try {
        application = [UIApplication sharedApplication];
    } @catch (__unused NSException *exception) {
        application = nil;
    }
    if (!application) {
        return nil;
    }
    return OPAIFindFirstWebView(OPAIApplicationWindows(application));
}

static long long OPAIWebDOMIndexFromElementId(NSString *elementId) {
    if (elementId.length == 0) {
        return -1;
    }
    NSRange range = [elementId rangeOfString:@"-web-" options:NSBackwardsSearch];
    if (range.location == NSNotFound) {
        return -1;
    }
    NSString *suffix = [elementId substringFromIndex:range.location + range.length];
    return suffix.length > 0 ? [suffix longLongValue] : -1;
}

static long long OPAIWebDOMIndexForAction(NSDictionary *action, NSDictionary *target) {
    long long domIndex = OPAINumberLongLong(target[@"dom_index"], -1);
    if (domIndex >= 0) {
        return domIndex;
    }
    NSString *elementId = OPAIString(action[@"element_id"]);
    return OPAIWebDOMIndexFromElementId(elementId);
}

static BOOL OPAIActionTargetsWebDOM(NSDictionary *action, NSDictionary *target) {
    NSString *scope = [target[@"scope"] isKindOfClass:[NSString class]] ? target[@"scope"] : @"";
    NSString *riskHint = [target[@"risk_hint"] isKindOfClass:[NSString class]] ? target[@"risk_hint"] : @"";
    NSString *elementId = OPAIString(action[@"element_id"]);
    return [scope isEqualToString:@"web_content_process"] ||
            [riskHint isEqualToString:@"web_content_process"] ||
            [elementId containsString:@"-web-"];
}

static NSString *OPAIWebDOMTextInputScript(long long domIndex, NSString *text) {
    NSString *textJSON = OPAIJSONStringLiteral(text ?: @"");
    return [NSString stringWithFormat:
        @"(function(){%@"
        "function opnodes(){var selector='input,textarea,select,button,a,[contenteditable=\"\"],[contenteditable=\"true\"],[role=\"textbox\"],[role=\"button\"],[tabindex]';"
        "return Array.prototype.slice.call(document.querySelectorAll(selector)).filter(function(el){var r=el.getBoundingClientRect();var s=getComputedStyle(el);"
        "return r.width>=1&&r.height>=1&&s.display!=='none'&&s.visibility!=='hidden'&&s.opacity!=='0';}).slice(0,80);}"
        "var nodes=opnodes();"
        "var index=%lld;var text=%@;var el=index>=0?nodes[index]:document.activeElement;"
        "if(!el||el===document.body||el===document.documentElement)return JSON.stringify({status:'unavailable',reason:'web_dom_target_not_found'});"
        "var tag=el.tagName.toLowerCase();var type=(el.getAttribute('type')||'').toLowerCase();"
        "var editable=(tag==='textarea'||(tag==='input'&&!['button','submit','reset','checkbox','radio','file','image','range','color'].includes(type))||el.isContentEditable||el.getAttribute('role')==='textbox');"
        "if(!editable)return JSON.stringify({status:'unavailable',reason:'web_dom_element_not_editable',tag:tag,type:type});"
        "var before=('value' in el)?String(el.value||''):String(el.textContent||'');"
        "el.focus({preventScroll:true});"
        "if('value' in el){var start=(typeof el.selectionStart==='number')?el.selectionStart:before.length;"
        "var end=(typeof el.selectionEnd==='number')?el.selectionEnd:start;"
        "el.value=before.slice(0,start)+text+before.slice(end);"
        "var pos=start+text.length;if(typeof el.setSelectionRange==='function')el.setSelectionRange(pos,pos);}"
        "else if(el.isContentEditable){document.execCommand('insertText',false,text);}"
        "var after=('value' in el)?String(el.value||''):String(el.textContent||'');"
        "try{el.dispatchEvent(new InputEvent('input',{bubbles:true,inputType:'insertText',data:text}));}catch(e){el.dispatchEvent(new Event('input',{bubbles:true}));}"
        "el.dispatchEvent(new Event('change',{bubbles:true}));"
        "return JSON.stringify({status:'ok',activation_method:'webkit_dom_text_input',tag:tag,type:type,focused:document.activeElement===el,before_text_length:before.length,after_text_length:after.length,text_length:text.length});"
        "})()",
        OPAIWebDOMQueryFunction(), domIndex, textJSON];
}

static NSString *OPAIWebDOMActivateScript(long long domIndex) {
    return [NSString stringWithFormat:
        @"(function(){%@"
        "function opnodes(){var selector='input,textarea,select,button,a,[contenteditable=\"\"],[contenteditable=\"true\"],[role=\"textbox\"],[role=\"button\"],[tabindex]';"
        "return Array.prototype.slice.call(document.querySelectorAll(selector)).filter(function(el){var r=el.getBoundingClientRect();var s=getComputedStyle(el);"
        "return r.width>=1&&r.height>=1&&s.display!=='none'&&s.visibility!=='hidden'&&s.opacity!=='0';}).slice(0,80);}"
        "var nodes=opnodes();"
        "var index=%lld;var el=index>=0?nodes[index]:null;"
        "if(!el)return JSON.stringify({status:'unavailable',reason:'web_dom_target_not_found'});"
        "var tag=el.tagName.toLowerCase();var type=(el.getAttribute('type')||'').toLowerCase();"
        "if(typeof el.scrollIntoView==='function')el.scrollIntoView({block:'center',inline:'center'});"
        "if(typeof el.focus==='function')el.focus({preventScroll:true});"
        "if(typeof el.click==='function')el.click();"
        "return JSON.stringify({status:'ok',activation_method:'webkit_dom_activate',tag:tag,type:type,focused:document.activeElement===el});"
        "})()",
        OPAIWebDOMQueryFunction(), domIndex];
}

static NSDictionary *OPAIWebDOMInputResponse(NSString *status,
        NSString *reason,
        NSString *actionType,
        NSDictionary *target,
        NSDictionary *extra) {
    NSMutableDictionary *metadata = [NSMutableDictionary dictionaryWithDictionary:extra ?: @{}];
    metadata[@"provider"] = @"OpenPhoneAppIntrospector.WebContentInput";
    metadata[@"scope"] = @"web_content_process";
    return OPAIInputResponse(status, reason, actionType, target, metadata);
}

static NSDictionary *OPAIPerformWebDOMInput(NSDictionary *action,
        NSDictionary *target,
        NSString *actionType,
        NSString *text) {
    UIView *webView = OPAISafariWebViewForInput();
    if (!webView) {
        return OPAIWebDOMInputResponse(@"unavailable", @"webview_not_found",
                actionType, target, nil);
    }
    long long domIndex = OPAIWebDOMIndexForAction(action, target);
    if (domIndex < 0 && ![actionType isEqualToString:@"type_text"]) {
        return OPAIWebDOMInputResponse(@"unavailable", @"web_dom_index_missing",
                actionType, target, nil);
    }
    NSDictionary *result = nil;
    if ([actionType isEqualToString:@"type_text"]) {
        result = OPAIWebViewEvaluateJSON(webView,
                OPAIWebDOMTextInputScript(domIndex, text ?: @""), 0.80);
    } else {
        result = OPAIWebViewEvaluateJSON(webView, OPAIWebDOMActivateScript(domIndex), 0.80);
    }
    if (![result[@"status"] isEqualToString:@"ok"]) {
        NSString *reason = [result[@"reason"] isKindOfClass:[NSString class]]
                ? result[@"reason"] : @"web_dom_input_failed";
        return OPAIWebDOMInputResponse(@"unavailable", reason, actionType, target, result);
    }
    NSMutableDictionary *extra = [result mutableCopy];
    extra[@"activation_method"] = result[@"activation_method"] ?:
            ([actionType isEqualToString:@"type_text"] ? @"webkit_dom_text_input" : @"webkit_dom_activate");
    extra[@"target_class"] = @"DOMElement";
    extra[@"dom_index"] = @(domIndex);
    return OPAIWebDOMInputResponse(@"ok", nil, actionType, target, extra);
}

static NSDictionary *OPAIPerformInputRequest(NSDictionary *pendingRequest) {
    NSDictionary *action = [pendingRequest[@"action"] isKindOfClass:[NSDictionary class]]
            ? pendingRequest[@"action"] : @{};
    NSString *actionType = OPAIString(action[@"type"]);
    if (![actionType isEqualToString:@"tap"] &&
            ![actionType isEqualToString:@"tap_element"] &&
            ![actionType isEqualToString:@"long_press"] &&
            ![actionType isEqualToString:@"type_text"]) {
        return OPAIInputResponse(@"unavailable", @"unsupported_action_type",
                actionType, nil, nil);
    }
    NSString *text = [action[@"text"] isKindOfClass:[NSString class]]
            ? action[@"text"] : @"";
    if ([actionType isEqualToString:@"type_text"] && text.length == 0) {
        return OPAIInputResponse(@"unavailable", @"missing_text",
                actionType, nil, nil);
    }
    long long durationMs = OPAILongLongForKey(action, @"duration_ms",
            [actionType isEqualToString:@"long_press"] ? 700 : 80, 50, 5000);
    NSDictionary *providedTarget = [action[@"target"] isKindOfClass:[NSDictionary class]]
            ? action[@"target"] : nil;
    if (OPAIActionTargetsWebDOM(action, providedTarget)) {
        return OPAIPerformWebDOMInput(action, providedTarget, actionType, text);
    }
    NSDictionary *target = nil;
    UIWindow *targetWindow = nil;
    UIView *targetView = nil;
    NSString *elementId = OPAIString(action[@"element_id"]);
    if (elementId.length > 0) {
        targetView = OPAIFindElementById(elementId, &target, &targetWindow);
    }
    if (!targetView) {
        double x = 0.0;
        double y = 0.0;
        if (OPAIDoubleForKey(action, @"x", &x) && OPAIDoubleForKey(action, @"y", &y)) {
            CGPoint point = OPAINormalizeInputPoint(x, y);
            targetView = OPAIHitTestView(point, &targetWindow, &target);
        }
    }
    if (!targetView && [actionType isEqualToString:@"type_text"]) {
        targetView = OPAIFindFirstResponder();
        if (targetView) {
            target = OPAIHitElementSummary(targetView, targetWindow ?: (UIWindow *)targetView.window);
        }
    }
    if (!targetView) {
        return OPAIInputResponse(@"unavailable", @"target_not_found",
                actionType, target, nil);
    }
    (void)targetWindow;
    if ([actionType isEqualToString:@"type_text"]) {
        return OPAITypeTextIntoView(targetView, target, text, actionType);
    }
    return OPAIActivateView(targetView, target, actionType, durationMs);
}

static void OPAIPollAndPerformInput(void) {
    @autoreleasepool {
        NSString *bundleId = OPAIEffectiveAppBundleId();
        NSDictionary *poll = OPAIDaemonRequest(@{
            @"command": @"app_input_poll",
            @"transport": @"app_process_tcp_loopback",
            @"bundle_id": bundleId,
            @"scope": OPAIElementScope()
        });
        if (![poll[@"status"] isEqualToString:@"ok"]) {
            return;
        }
        NSDictionary *pendingRequest = [poll[@"request"] isKindOfClass:[NSDictionary class]]
                ? poll[@"request"] : nil;
        NSString *requestId = OPAIString(pendingRequest[@"request_id"]);
        if (!pendingRequest || requestId.length == 0) {
            return;
        }

        __block NSDictionary *response = nil;
        void (^performBlock)(void) = ^{
            @try {
                response = OPAIPerformInputRequest(pendingRequest);
            } @catch (NSException *exception) {
                response = OPAIInputResponse(@"unavailable", @"perform_exception",
                        OPAIString([pendingRequest[@"action"] isKindOfClass:[NSDictionary class]]
                                ? pendingRequest[@"action"][@"type"] : @""),
                        nil,
                        @{
                            @"exception_name": exception.name ?: @"",
                            @"exception_reason": exception.reason ?: @""
                        });
            }
        };
        if ([NSThread isMainThread]) {
            performBlock();
        } else {
            dispatch_sync(dispatch_get_main_queue(), performBlock);
        }
        if (!response) {
            response = OPAIInputResponse(@"unavailable", @"empty_perform_response",
                    OPAIString([pendingRequest[@"action"] isKindOfClass:[NSDictionary class]]
                            ? pendingRequest[@"action"][@"type"] : @""),
                    nil, nil);
        }

        NSDictionary *complete = OPAIDaemonRequest(@{
            @"command": @"app_input_complete",
            @"transport": @"app_process_tcp_loopback",
            @"bundle_id": bundleId,
            @"request_id": requestId,
            @"response": response
        });
        if (![complete[@"status"] isEqualToString:@"ok"]) {
            OPAILog(@"app input complete failed request_id=%@ reason=%@",
                    requestId, OPAIString(complete[@"reason"]));
        }
    }
}

static void *OPAIStateThread(void *unused) {
    (void)unused;
    usleep(1500000);
    long long lastPublishMs = 0;
    while (1) {
        long long now = OPAINowMs();
        if (now - lastPublishMs >= 2000) {
            OPAIPublishAppStateOnMain();
            lastPublishMs = now;
        }
        OPAIPollAndPerformInput();
        usleep(350000);
    }
    return NULL;
}

__attribute__((constructor))
static void OPAIInit(void) {
    NSString *bundleId = OPAIAppBundleId();
    // SpringBoard is owned by OpenPhoneVolumeTrigger, which drives the island
    // overlay and its own input bridge. Running the introspector's publish/input
    // loop there too would fight over the daemon's app-input socket, so stay out.
    if ([bundleId isEqualToString:@"com.apple.springboard"]) {
        return;
    }
    OPAILog(@"OpenPhoneAppIntrospector loaded bundle=%@ pid=%d",
            bundleId ?: @"", getpid());
    pthread_t thread;
    int rc = pthread_create(&thread, NULL, OPAIStateThread, NULL);
    if (rc == 0) {
        pthread_detach(thread);
    } else {
        OPAILog(@"state thread failed rc=%d", rc);
    }
}
