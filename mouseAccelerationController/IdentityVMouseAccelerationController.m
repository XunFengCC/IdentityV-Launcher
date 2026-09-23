#import <Cocoa/Cocoa.h>
#import <IOKit/hidsystem/IOHIDEventSystemClient.h>
#import <IOKit/hidsystem/IOHIDServiceClient.h>
#import <signal.h>
#import <errno.h>
#import <fcntl.h>
#import <stdint.h>
#import <stdlib.h>
#import <sys/stat.h>
#import <unistd.h>

static NSString *const kLinearAccelerationKey = @"HIDUseLinearScalingMouseAcceleration";
static NSString *const kTargetBundleID = @"com.xunfeng.identityv.mac";

typedef struct {
    NSInteger vendorID;
    NSInteger productID;
    BOOL isConfigured;
} DeviceSelector;

// IOHIDServiceClientRef values returned by IOHIDEventSystemClientCopyServices
// remain backed by their event-system client.  Keep both references together:
// retaining only the service and tearing down the client leaves a dangling
// service on newer macOS releases.
typedef struct {
    IOHIDEventSystemClientRef client;
    IOHIDServiceClientRef service;
} TargetMouse;

static BOOL parseDeviceIdentifier(const char *text, NSInteger *value) {
    if (text == NULL || *text == '\0') {
        return NO;
    }
    char *end = NULL;
    long parsed = strtol(text, &end, 0);
    if (end == text || *end != '\0' || parsed <= 0 || parsed > UINT16_MAX) {
        return NO;
    }
    *value = (NSInteger)parsed;
    return YES;
}

static DeviceSelector deviceSelectorFromArguments(int argc, const char *argv[]) {
    DeviceSelector selector = { 0, 0, NO };
    BOOL hasVendorID = NO;
    BOOL hasProductID = NO;
    for (int index = 2; index < argc; index++) {
        if (strcmp(argv[index], "--vendor-id") == 0 && index + 1 < argc) {
            hasVendorID = parseDeviceIdentifier(argv[++index], &selector.vendorID);
        } else if (strcmp(argv[index], "--product-id") == 0 && index + 1 < argc) {
            hasProductID = parseDeviceIdentifier(argv[++index], &selector.productID);
        }
    }
    selector.isConfigured = hasVendorID && hasProductID;
    return selector;
}

static NSNumber *numberProperty(IOHIDServiceClientRef service, CFStringRef key) {
    CFTypeRef value = IOHIDServiceClientCopyProperty(service, key);
    if (value == NULL) {
        return nil;
    }
    id object = CFBridgingRelease(value);
    return [object isKindOfClass:[NSNumber class]] ? object : nil;
}

static NSString *stringProperty(IOHIDServiceClientRef service, CFStringRef key) {
    CFTypeRef value = IOHIDServiceClientCopyProperty(service, key);
    if (value == NULL) {
        return nil;
    }
    id object = CFBridgingRelease(value);
    return [object isKindOfClass:[NSString class]] ? object : nil;
}

static void releaseTargetMouse(TargetMouse *target) {
    if (target->service != NULL) {
        CFRelease(target->service);
        target->service = NULL;
    }
    if (target->client != NULL) {
        CFRelease(target->client);
        target->client = NULL;
    }
}

static TargetMouse copyTargetMouse(DeviceSelector selector) {
    TargetMouse target = { NULL, NULL };
    if (!selector.isConfigured) {
        return target;
    }
    IOHIDEventSystemClientRef client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault);
    if (client == NULL) {
        return target;
    }

    CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
    if (services != NULL) {
        CFIndex count = CFArrayGetCount(services);
        for (CFIndex index = 0; index < count; index++) {
            IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, index);
            NSNumber *vendor = numberProperty(service, CFSTR("VendorID"));
            NSNumber *product = numberProperty(service, CFSTR("ProductID"));
            NSNumber *usagePage = numberProperty(service, CFSTR("PrimaryUsagePage"));
            NSNumber *usage = numberProperty(service, CFSTR("PrimaryUsage"));
            if (vendor.integerValue == selector.vendorID &&
                product.integerValue == selector.productID &&
                usagePage.integerValue == 1 &&
                usage.integerValue == 2) {
                target.client = client;
                target.service = (IOHIDServiceClientRef)CFRetain(service);
                break;
            }
        }
        CFRelease(services);
    }
    if (target.service == NULL) {
        CFRelease(client);
    }
    return target;
}

static BOOL setLinearAcceleration(IOHIDServiceClientRef service, NSInteger value) {
    NSNumber *number = @(value);
    return IOHIDServiceClientSetProperty(
        service,
        (__bridge CFStringRef)kLinearAccelerationKey,
        (__bridge CFTypeRef)number
    );
}

static BOOL clearLinearAcceleration(IOHIDServiceClientRef service) {
    return IOHIDServiceClientSetProperty(
        service,
        (__bridge CFStringRef)kLinearAccelerationKey,
        kCFNull
    );
}

static NSString *stateFileFromArguments(int argc, const char *argv[]) {
    for (int index = 2; index < argc; index++) {
        if (strcmp(argv[index], "--state-file") == 0 && index + 1 < argc) {
            return [NSString stringWithUTF8String:argv[index + 1]];
        }
    }
    return nil;
}

static BOOL writeAll(int fileDescriptor, const uint8_t *bytes, NSUInteger length) {
    NSUInteger offset = 0;
    while (offset < length) {
        ssize_t written = write(fileDescriptor, bytes + offset, length - offset);
        if (written <= 0) {
            return NO;
        }
        offset += (NSUInteger)written;
    }
    return YES;
}

static BOOL writeSessionState(NSString *stateFile, DeviceSelector selector, NSNumber *originalValue) {
    NSDictionary *state = @{
        @"version": @1,
        @"vendorID": @(selector.vendorID),
        @"productID": @(selector.productID),
        @"linearAcceleration": originalValue ?: [NSNull null]
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
    if (data == nil) {
        return NO;
    }
    NSString *template = [stateFile stringByAppendingString:@".tmp.XXXXXX"];
    char *templatePath = strdup(template.fileSystemRepresentation);
    if (templatePath == NULL) {
        return NO;
    }
    int descriptor = mkstemp(templatePath);
    BOOL written = descriptor >= 0;
    if (written) {
        written = fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 &&
            writeAll(descriptor, data.bytes, data.length) && fsync(descriptor) == 0 && close(descriptor) == 0;
    }
    if (!written && descriptor >= 0) {
        close(descriptor);
    }
    if (written) {
        written = rename(templatePath, stateFile.fileSystemRepresentation) == 0 &&
            chmod(stateFile.fileSystemRepresentation, S_IRUSR | S_IWUSR) == 0;
    }
    if (!written) {
        unlink(templatePath);
    }
    free(templatePath);
    return written;
}

static NSDictionary *readSessionState(NSString *stateFile, DeviceSelector selector, NSString **error) {
    struct stat attributes;
    if (lstat(stateFile.fileSystemRepresentation, &attributes) != 0) {
        if (errno == ENOENT) {
            return nil;
        }
        *error = @"cannot inspect mouse acceleration session state";
        return @{};
    }
    if (!S_ISREG(attributes.st_mode) || (attributes.st_mode & (S_IRWXG | S_IRWXO)) != 0) {
        *error = @"mouse acceleration session state is not a private regular file";
        return @{};
    }
    NSData *data = [NSData dataWithContentsOfFile:stateFile options:0 error:nil];
    id object = data == nil ? nil : [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![object isKindOfClass:[NSDictionary class]]) {
        *error = @"mouse acceleration session state is invalid";
        return @{};
    }
    NSDictionary *state = object;
    NSNumber *version = state[@"version"];
    NSNumber *vendorID = state[@"vendorID"];
    NSNumber *productID = state[@"productID"];
    id originalValue = state[@"linearAcceleration"];
    if (![version isKindOfClass:[NSNumber class]] || version.integerValue != 1 ||
        ![vendorID isKindOfClass:[NSNumber class]] || vendorID.integerValue != selector.vendorID ||
        ![productID isKindOfClass:[NSNumber class]] || productID.integerValue != selector.productID ||
        !([originalValue isKindOfClass:[NSNumber class]] || originalValue == [NSNull null])) {
        *error = @"mouse acceleration session state does not match the selected pointing device";
        return @{};
    }
    return state;
}

static BOOL stateMatchesLinearAcceleration(IOHIDServiceClientRef service, id expected) {
    NSNumber *current = numberProperty(service, (__bridge CFStringRef)kLinearAccelerationKey);
    if (expected == [NSNull null]) {
        return current == nil;
    }
    return [expected isKindOfClass:[NSNumber class]] && current != nil && current.integerValue == [expected integerValue];
}

static BOOL restoreSessionState(TargetMouse *target, DeviceSelector selector, NSString *stateFile,
                                BOOL *didRestore, NSString **error) {
    *didRestore = NO;
    NSDictionary *state = readSessionState(stateFile, selector, error);
    if (state == nil) {
        return YES;
    }
    if (state.count == 0) {
        return NO;
    }
    id originalValue = state[@"linearAcceleration"];
    BOOL restored = originalValue == [NSNull null] ? clearLinearAcceleration(target->service) :
        setLinearAcceleration(target->service, [originalValue integerValue]);
    if (!restored || !stateMatchesLinearAcceleration(target->service, originalValue)) {
        *error = @"cannot restore the selected pointing device's original acceleration state";
        return NO;
    }
    if (unlink(stateFile.fileSystemRepresentation) != 0) {
        *error = @"restored mouse acceleration but cannot clear private session state";
        return NO;
    }
    *didRestore = YES;
    return YES;
}

static NSDictionary *mouseStatus(IOHIDServiceClientRef service, DeviceSelector selector) {
    if (!selector.isConfigured) {
        return @{
            @"configured": @NO,
            @"found": @NO,
            @"error": @"no pointing device has been selected"
        };
    }
    if (service == NULL) {
        return @{
            @"configured": @YES,
            @"found": @NO,
            @"vendorID": @(selector.vendorID),
            @"productID": @(selector.productID)
        };
    }
    NSNumber *linear = numberProperty(service, (__bridge CFStringRef)kLinearAccelerationKey);
    NSString *name = stringProperty(service, CFSTR("Product")) ?: @"Selected pointing device";
    return @{
        @"configured": @YES,
        @"found": @YES,
        @"name": name,
        @"vendorID": @(selector.vendorID),
        @"productID": @(selector.productID),
        @"linearAcceleration": linear ?: [NSNull null]
    };
}

static void printJSON(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    if (data != nil) {
        fwrite(data.bytes, 1, data.length, stdout);
        fputc('\n', stdout);
    }
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSString *mode = argc > 1 ? [NSString stringWithUTF8String:argv[1]] : @"--status";
        DeviceSelector selector = deviceSelectorFromArguments(argc, argv);
        TargetMouse target = copyTargetMouse(selector);

        if ([mode isEqualToString:@"--status"]) {
            printJSON(mouseStatus(target.service, selector));
            releaseTargetMouse(&target);
            return 0;
        }
        if (!selector.isConfigured) {
            printJSON(mouseStatus(NULL, selector));
            return 64;
        }
        if (target.service == NULL) {
            printJSON(@{
                @"configured": @YES,
                @"found": @NO,
                @"error": @"the selected pointing device is not connected",
                @"vendorID": @(selector.vendorID),
                @"productID": @(selector.productID)
            });
            return 2;
        }
        if ([mode isEqualToString:@"--disable-once"] || [mode isEqualToString:@"--restore-once"]) {
            NSInteger value = [mode isEqualToString:@"--disable-once"] ? 1 : 0;
            BOOL changed = setLinearAcceleration(target.service, value);
            NSMutableDictionary *status = [mouseStatus(target.service, selector) mutableCopy];
            status[@"changed"] = @(changed);
            printJSON(status);
            releaseTargetMouse(&target);
            return changed ? 0 : 3;
        }

        NSString *stateFile = stateFileFromArguments(argc, argv);
        if (([mode isEqualToString:@"--begin-session"] || [mode isEqualToString:@"--end-session"]) && stateFile.length == 0) {
            printJSON(@{ @"error": @"a private --state-file is required for a mouse acceleration session" });
            releaseTargetMouse(&target);
            return 64;
        }
        if ([mode isEqualToString:@"--end-session"]) {
            BOOL didRestore = NO;
            NSString *error = nil;
            BOOL ended = restoreSessionState(&target, selector, stateFile, &didRestore, &error);
            printJSON(@{
                @"configured": @YES,
                @"found": @YES,
                @"ended": @(ended),
                @"restored": @(didRestore),
                @"error": error ?: [NSNull null]
            });
            releaseTargetMouse(&target);
            return ended ? 0 : 4;
        }
        if ([mode isEqualToString:@"--begin-session"]) {
            BOOL didRecover = NO;
            NSString *error = nil;
            if (!restoreSessionState(&target, selector, stateFile, &didRecover, &error)) {
                printJSON(@{ @"begun": @NO, @"recoveredPrevious": @NO, @"error": error ?: @"cannot recover a prior mouse session" });
                releaseTargetMouse(&target);
                return 4;
            }
            NSNumber *originalValue = numberProperty(target.service, (__bridge CFStringRef)kLinearAccelerationKey);
            if (!writeSessionState(stateFile, selector, originalValue)) {
                printJSON(@{ @"begun": @NO, @"recoveredPrevious": @(didRecover), @"error": @"cannot create private mouse acceleration session state" });
                releaseTargetMouse(&target);
                return 4;
            }
            BOOL configured = setLinearAcceleration(target.service, 1) &&
                stateMatchesLinearAcceleration(target.service, @1);
            if (!configured) {
                NSString *restoreError = nil;
                BOOL didRestore = NO;
                (void)restoreSessionState(&target, selector, stateFile, &didRestore, &restoreError);
                printJSON(@{ @"begun": @NO, @"recoveredPrevious": @(didRecover), @"error": @"cannot enable linear mouse acceleration mode" });
                releaseTargetMouse(&target);
                return 4;
            }
            printJSON(@{ @"begun": @YES, @"recoveredPrevious": @(didRecover), @"linearAcceleration": @1 });
            releaseTargetMouse(&target);
            return 0;
        }

        printJSON(@{ @"error": @"unsupported mode" });
        releaseTargetMouse(&target);
        return 64;
    }
}
