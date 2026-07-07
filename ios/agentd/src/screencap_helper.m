#import <Foundation/Foundation.h>

#import <CommonCrypto/CommonDigest.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <stdint.h>
#import <string.h>
#import <sys/stat.h>
#import <unistd.h>

typedef int (*OPIOMFBGetMainDisplayFunc)(void **connection);
typedef int (*OPIOMFBOpenFunc)(uint32_t service, mach_port_t owningTask,
        uint32_t type, void **connection);
typedef int (*OPIOMFBGetLayerDefaultSurfaceFunc)(void *connection, int layer, void **surface);
typedef CFMutableDictionaryRef (*OPIOServiceMatchingFunc)(const char *name);
typedef uint32_t (*OPIOServiceGetMatchingServiceFunc)(uint32_t mainPort,
        CFDictionaryRef matching);
typedef int (*OPIOObjectReleaseFunc)(uint32_t object);
typedef int (*OPIOSurfaceLockFunc)(void *surface, uint32_t options, uint32_t *seed);
typedef int (*OPIOSurfaceUnlockFunc)(void *surface, uint32_t options, uint32_t *seed);
typedef void *(*OPIOSurfaceGetBaseAddressFunc)(void *surface);
typedef size_t (*OPIOSurfaceGetWidthFunc)(void *surface);
typedef size_t (*OPIOSurfaceGetHeightFunc)(void *surface);
typedef size_t (*OPIOSurfaceGetBytesPerRowFunc)(void *surface);
typedef uint32_t (*OPIOSurfaceGetPixelFormatFunc)(void *surface);

static NSString *const OPDefaultStorePath = @"/var/mobile/Library/OpenPhone";

static NSString *OPNowFilename(void) {
    long long ms = (long long)([[NSDate date] timeIntervalSince1970] * 1000.0);
    return [NSString stringWithFormat:@"screen-%lld-%d.png", ms, getpid()];
}

static NSString *OPSHA256Hex(NSData *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (NSUInteger i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

static void OPPrintJSON(NSDictionary *object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object ?: @{}
                                                   options:0
                                                     error:nil];
    if (!data) {
        data = [@"{\"status\":\"error\",\"reason\":\"json_encode_failed\"}"
                dataUsingEncoding:NSUTF8StringEncoding];
    }
    fwrite(data.bytes, 1, data.length, stdout);
    fputc('\n', stdout);
}

static NSString *OPOutputPath(int argc, const char *argv[]) {
    if (argc >= 2 && argv[1] && argv[1][0] != '\0') {
        return [NSString stringWithUTF8String:argv[1]];
    }
    NSString *directory = [[OPDefaultStorePath stringByAppendingPathComponent:@"screenshots"] copy];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions: @0755}
                                                    error:nil];
    return [directory stringByAppendingPathComponent:OPNowFilename()];
}

// Downscale so the longest edge is at most maxDimension points. Returns a new
// CGImage the caller must release, or NULL if no scaling was needed.
static CGImageRef OPCreateScaledImage(CGImageRef source, size_t maxDimension,
        size_t *scaledWidthOut, size_t *scaledHeightOut) {
    if (!source || maxDimension == 0) {
        return NULL;
    }
    size_t width = CGImageGetWidth(source);
    size_t height = CGImageGetHeight(source);
    size_t longest = MAX(width, height);
    if (longest <= maxDimension) {
        return NULL;
    }
    double scale = (double)maxDimension / (double)longest;
    size_t scaledWidth = MAX((size_t)1, (size_t)llround((double)width * scale));
    size_t scaledHeight = MAX((size_t)1, (size_t)llround((double)height * scale));
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(NULL, scaledWidth, scaledHeight, 8,
            0, colorSpace, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    if (colorSpace) {
        CGColorSpaceRelease(colorSpace);
    }
    if (!context) {
        return NULL;
    }
    CGContextSetInterpolationQuality(context, kCGInterpolationMedium);
    CGContextDrawImage(context, CGRectMake(0, 0, scaledWidth, scaledHeight), source);
    CGImageRef scaled = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (scaled) {
        if (scaledWidthOut) *scaledWidthOut = scaledWidth;
        if (scaledHeightOut) *scaledHeightOut = scaledHeight;
    }
    return scaled;
}

static NSDictionary *OPUnavailable(NSString *reason, NSDictionary *extra) {
    NSMutableDictionary *result = [@{
        @"status": @"unavailable",
        @"provider": @"IOMobileFramebuffer.IOSurface",
        @"reason": reason ?: @"unknown"
    } mutableCopy];
    [result addEntriesFromDictionary:extra ?: @{}];
    return result;
}

static NSDictionary *OPCapture(NSString *path, size_t maxDimension, double jpegQuality) {
    void *iomfb = dlopen("/System/Library/PrivateFrameworks/IOMobileFramebuffer.framework/IOMobileFramebuffer",
            RTLD_LAZY);
    void *iosurface = dlopen("/System/Library/Frameworks/IOSurface.framework/IOSurface",
            RTLD_LAZY);
    if (!iosurface) {
        iosurface = dlopen("/System/Library/PrivateFrameworks/IOSurface.framework/IOSurface",
                RTLD_LAZY);
    }
    if (!iomfb || !iosurface) {
        return OPUnavailable(@"framework_unavailable", @{
            @"iomobileframebuffer_loaded": @(iomfb != NULL),
            @"iosurface_loaded": @(iosurface != NULL)
        });
    }

    OPIOMFBGetMainDisplayFunc getMainDisplay =
            (OPIOMFBGetMainDisplayFunc)dlsym(iomfb, "IOMobileFramebufferGetMainDisplay");
    OPIOMFBOpenFunc openFramebuffer =
            (OPIOMFBOpenFunc)dlsym(iomfb, "IOMobileFramebufferOpen");
    OPIOMFBGetLayerDefaultSurfaceFunc getLayerDefaultSurface =
            (OPIOMFBGetLayerDefaultSurfaceFunc)dlsym(iomfb, "IOMobileFramebufferGetLayerDefaultSurface");
    OPIOSurfaceLockFunc surfaceLock =
            (OPIOSurfaceLockFunc)dlsym(iosurface, "IOSurfaceLock");
    OPIOSurfaceUnlockFunc surfaceUnlock =
            (OPIOSurfaceUnlockFunc)dlsym(iosurface, "IOSurfaceUnlock");
    OPIOSurfaceGetBaseAddressFunc surfaceBaseAddress =
            (OPIOSurfaceGetBaseAddressFunc)dlsym(iosurface, "IOSurfaceGetBaseAddress");
    OPIOSurfaceGetWidthFunc surfaceWidth =
            (OPIOSurfaceGetWidthFunc)dlsym(iosurface, "IOSurfaceGetWidth");
    OPIOSurfaceGetHeightFunc surfaceHeight =
            (OPIOSurfaceGetHeightFunc)dlsym(iosurface, "IOSurfaceGetHeight");
    OPIOSurfaceGetBytesPerRowFunc surfaceBytesPerRow =
            (OPIOSurfaceGetBytesPerRowFunc)dlsym(iosurface, "IOSurfaceGetBytesPerRow");
    OPIOSurfaceGetPixelFormatFunc surfacePixelFormat =
            (OPIOSurfaceGetPixelFormatFunc)dlsym(iosurface, "IOSurfaceGetPixelFormat");

    NSDictionary *symbols = @{
        @"IOMobileFramebufferGetMainDisplay": @(getMainDisplay != NULL),
        @"IOMobileFramebufferOpen": @(openFramebuffer != NULL),
        @"IOMobileFramebufferGetLayerDefaultSurface": @(getLayerDefaultSurface != NULL),
        @"IOSurfaceLock": @(surfaceLock != NULL),
        @"IOSurfaceUnlock": @(surfaceUnlock != NULL),
        @"IOSurfaceGetBaseAddress": @(surfaceBaseAddress != NULL),
        @"IOSurfaceGetWidth": @(surfaceWidth != NULL),
        @"IOSurfaceGetHeight": @(surfaceHeight != NULL),
        @"IOSurfaceGetBytesPerRow": @(surfaceBytesPerRow != NULL),
        @"IOSurfaceGetPixelFormat": @(surfacePixelFormat != NULL)
    };
    if (!getMainDisplay || !getLayerDefaultSurface || !surfaceLock || !surfaceUnlock
            || !surfaceBaseAddress || !surfaceWidth || !surfaceHeight || !surfaceBytesPerRow) {
        return OPUnavailable(@"required_symbol_unavailable", @{@"symbols": symbols});
    }

    void *connection = NULL;
    int mainResult = getMainDisplay(&connection);
    NSMutableDictionary *acquisition = [@{
        @"main_display_kern_return": @(mainResult),
        @"main_display_ok": @(mainResult == 0 && connection != NULL)
    } mutableCopy];
    if (mainResult != 0 || !connection) {
        void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
        if (!iokit) {
            iokit = dlopen("/System/Library/PrivateFrameworks/IOKit.framework/IOKit", RTLD_LAZY);
        }
        OPIOServiceMatchingFunc serviceMatching = iokit
                ? (OPIOServiceMatchingFunc)dlsym(iokit, "IOServiceMatching") : NULL;
        OPIOServiceGetMatchingServiceFunc getMatchingService = iokit
                ? (OPIOServiceGetMatchingServiceFunc)dlsym(iokit, "IOServiceGetMatchingService") : NULL;
        OPIOObjectReleaseFunc objectRelease = iokit
                ? (OPIOObjectReleaseFunc)dlsym(iokit, "IOObjectRelease") : NULL;
        acquisition[@"iokit_loaded"] = @(iokit != NULL);
        acquisition[@"IOServiceMatching"] = @(serviceMatching != NULL);
        acquisition[@"IOServiceGetMatchingService"] = @(getMatchingService != NULL);
        acquisition[@"IOObjectRelease"] = @(objectRelease != NULL);
        acquisition[@"open_symbol"] = @(openFramebuffer != NULL);
        if (openFramebuffer && serviceMatching && getMatchingService) {
            CFMutableDictionaryRef matching = serviceMatching("IOMobileFramebuffer");
            uint32_t service = matching ? getMatchingService(0, matching) : 0;
            acquisition[@"service"] = @(service);
            if (service != 0) {
                int openResult = openFramebuffer(service, mach_task_self(), 0, &connection);
                acquisition[@"open_kern_return"] = @(openResult);
                acquisition[@"open_ok"] = @(openResult == 0 && connection != NULL);
                if (objectRelease) {
                    objectRelease(service);
                }
            }
        }
    }
    if (!connection) {
        return OPUnavailable(@"display_connection_unavailable", @{
            @"kern_return": @(mainResult),
            @"acquisition": acquisition,
            @"symbols": symbols
        });
    }

    void *surface = NULL;
    int surfaceResult = getLayerDefaultSurface(connection, 0, &surface);
    if (surfaceResult != 0 || !surface) {
        return OPUnavailable(@"default_surface_unavailable", @{
            @"kern_return": @(surfaceResult),
            @"symbols": symbols
        });
    }

    const uint32_t readOnly = 1;
    uint32_t seed = 0;
    int lockResult = surfaceLock(surface, readOnly, &seed);
    if (lockResult != 0) {
        return OPUnavailable(@"surface_lock_failed", @{
            @"kern_return": @(lockResult),
            @"symbols": symbols
        });
    }

    void *base = surfaceBaseAddress(surface);
    size_t width = surfaceWidth(surface);
    size_t height = surfaceHeight(surface);
    size_t bytesPerRow = surfaceBytesPerRow(surface);
    uint32_t pixelFormat = surfacePixelFormat ? surfacePixelFormat(surface) : 0;
    if (!base || width == 0 || height == 0 || bytesPerRow == 0) {
        surfaceUnlock(surface, readOnly, &seed);
        return OPUnavailable(@"surface_geometry_unavailable", @{
            @"width": @(width),
            @"height": @(height),
            @"bytes_per_row": @(bytesPerRow),
            @"symbols": symbols
        });
    }

    NSMutableData *pixels = [NSMutableData dataWithLength:bytesPerRow * height];
    memcpy(pixels.mutableBytes, base, pixels.length);
    surfaceUnlock(surface, readOnly, &seed);

    NSString *directory = [path stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:directory
                              withIntermediateDirectories:YES
                                               attributes:@{NSFilePosixPermissions: @0755}
                                                    error:nil];

    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGBitmapInfo bitmapInfo = kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst;
    CGImageRef image = CGImageCreate(width, height, 8, 32, bytesPerRow, colorSpace,
            bitmapInfo, provider, NULL, false, kCGRenderingIntentDefault);
    if (colorSpace) {
        CGColorSpaceRelease(colorSpace);
    }
    if (provider) {
        CGDataProviderRelease(provider);
    }
    if (!image) {
        return OPUnavailable(@"cgimage_create_failed", @{
            @"width": @(width),
            @"height": @(height),
            @"bytes_per_row": @(bytesPerRow),
            @"pixel_format": @(pixelFormat),
            @"symbols": symbols
        });
    }

    // Optionally downscale so the longest edge is <= maxDimension. Cuts the
    // encoded size (and downstream base64/model memory) ~4x on a 1290px-wide
    // phone screen scaled to 1024px, more when combined with JPEG.
    size_t encodedWidth = width;
    size_t encodedHeight = height;
    CGImageRef scaled = OPCreateScaledImage(image, maxDimension, &encodedWidth, &encodedHeight);
    CGImageRef encodeImage = scaled ? scaled : image;

    NSString *lowerPath = [path lowercaseString];
    BOOL wantJPEG = [lowerPath hasSuffix:@".jpg"] || [lowerPath hasSuffix:@".jpeg"];
    CFStringRef utType = wantJPEG ? CFSTR("public.jpeg") : CFSTR("public.png");

    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL(
            (__bridge CFURLRef)url, utType, 1, NULL);
    if (!destination) {
        if (scaled) CGImageRelease(scaled);
        CGImageRelease(image);
        return OPUnavailable(@"image_destination_failed", @{
            @"path": path ?: @"",
            @"symbols": symbols
        });
    }
    NSDictionary *destProperties = wantJPEG ? @{
        (__bridge NSString *)kCGImageDestinationLossyCompressionQuality:
                @(MAX(0.1, MIN(1.0, jpegQuality)))
    } : @{};
    CGImageDestinationAddImage(destination, encodeImage,
            (__bridge CFDictionaryRef)destProperties);
    BOOL finalized = CGImageDestinationFinalize(destination);
    CFRelease(destination);
    if (scaled) CGImageRelease(scaled);
    CGImageRelease(image);
    if (!finalized) {
        return OPUnavailable(@"image_write_failed", @{
            @"path": path ?: @"",
            @"symbols": symbols
        });
    }

    NSData *encoded = [NSData dataWithContentsOfFile:path];
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil] ?: @{};
    return @{
        @"status": @"ok",
        @"provider": @"IOMobileFramebuffer.IOSurface",
        @"path": path ?: @"",
        @"format": wantJPEG ? @"jpeg" : @"png",
        @"width": @(encodedWidth),
        @"height": @(encodedHeight),
        @"source_width": @(width),
        @"source_height": @(height),
        @"max_dimension": @(maxDimension),
        @"jpeg_quality": wantJPEG ? @(MAX(0.1, MIN(1.0, jpegQuality))) : @0,
        @"bytes_per_row": @(bytesPerRow),
        @"pixel_format": @(pixelFormat),
        @"bytes": attributes[NSFileSize] ?: @(encoded.length),
        @"sha256": encoded ? OPSHA256Hex(encoded) : @"",
        @"symbols": symbols
    };
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *path = OPOutputPath(argc, argv);
        // argv[2] = max longest-edge dimension in px (0 disables scaling).
        // argv[3] = JPEG quality 0.1-1.0 (only used when path ends .jpg/.jpeg).
        size_t maxDimension = (argc >= 3 && argv[2]) ? (size_t)strtoul(argv[2], NULL, 10) : 0;
        double jpegQuality = (argc >= 4 && argv[3]) ? strtod(argv[3], NULL) : 0.6;
        if (jpegQuality <= 0.0) {
            jpegQuality = 0.6;
        }
        @try {
            OPPrintJSON(OPCapture(path, maxDimension, jpegQuality));
        } @catch (NSException *exception) {
            OPPrintJSON(OPUnavailable(@"exception", @{
                @"name": exception.name ?: @"",
                @"detail": exception.reason ?: @""
            }));
        }
    }
    return 0;
}
