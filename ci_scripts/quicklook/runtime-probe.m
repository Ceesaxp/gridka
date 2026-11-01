#import <Foundation/Foundation.h>
#import <Quartz/Quartz.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#include <sys/sysctl.h>
#include <stdlib.h>
#include <string.h>

// Loaded into a test-only copy of the Release extension, before NSExtensionMain.
// Do not define PreviewProvider here: all class metadata must come from the appex.
static unsigned failures = 0;

static void check(BOOL passed, const char *name) {
    fprintf(stdout, "%s %s\n", passed ? "PASS" : "FAIL", name);
    if (!passed) failures++;
}

static BOOL booleanValue(id value, BOOL expected) {
    return value && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()
        && [value boolValue] == expected;
}

__attribute__((constructor)) static void inspectQuickLook(void) {
    @autoreleasepool {
#if defined(__arm64__)
        check(YES, "arm64 process");
#else
        check(NO, "arm64 process");
#endif
        int translated = 0;
        size_t size = sizeof(translated);
        // This key may be absent in a native process; it is 1 under Rosetta.
        int status = sysctlbyname("sysctl.proc_translated", &translated, &size, NULL, 0);
        check(status != 0 || translated == 0, "native execution (no Rosetta)");

        const char *plistPath = getenv("GRIDKA_QUICKLOOK_PLIST");
        NSDictionary *plist = plistPath
            ? [NSDictionary dictionaryWithContentsOfFile:@(plistPath)] : nil;
        check(plist != nil, "built Info.plist is readable");
        NSDictionary *extension = plist[@"NSExtension"];
        NSDictionary *attributes = extension[@"NSExtensionAttributes"];
        check([extension[@"NSExtensionPointIdentifier"] isEqual:@"com.apple.quicklook.preview"],
              "Quick Look extension point");
        NSString *principal = extension[@"NSExtensionPrincipalClass"];
        check([principal isEqual:@"GridkaQuickLook.PreviewProvider"], "expanded principal class");
        check(booleanValue(attributes[@"QLIsDataBasedPreview"], YES), "data-based preview flag");
        check(booleanValue(attributes[@"QLSupportsSearchableItems"], NO), "searchable items flag");
        NSArray *types = attributes[@"QLSupportedContentTypes"];
        NSSet *expected = [NSSet setWithArray:@[@"public.comma-separated-values-text",
            @"public.tab-separated-values-text", @"public.delimited-values-text"]];
        check([types isKindOfClass:[NSArray class]] && types.count == expected.count
              && [[NSSet setWithArray:types] isEqual:expected], "supported content types (including TSV)");
        for (NSString *key in @[@"QLIsDataBasedPreview", @"QLSupportsSearchableItems", @"QLSupportedContentTypes"]) {
            check(!plist[key] && !extension[key],
                  [[@"attributes nested only: " stringByAppendingString:key] UTF8String]);
        }

        Class provider = [principal isKindOfClass:[NSString class]] ? NSClassFromString(principal) : Nil;
        check(provider != Nil, "principal class resolves in extension process");
        const char *image = provider ? class_getImageName(provider) : NULL;
        const char *mainImage = _dyld_get_image_name(0);
        check(image && mainImage && strcmp(image, mainImage) == 0,
              "provider belongs to actual extension executable");
        check(provider && class_getSuperclass(provider) == [QLPreviewProvider class], "QLPreviewProvider superclass");
        check(provider && class_conformsToProtocol(provider, @protocol(QLPreviewingController)),
              "QLPreviewingController conformance");

        SEL callback = sel_registerName("providePreviewForFileRequest:completionHandler:");
        unsigned count = 0;
        Method *methods = provider ? class_copyMethodList(provider, &count) : NULL;
        BOOL ownsCallback = NO;
        for (unsigned i = 0; i < count; i++) {
            if (sel_isEqual(method_getName(methods[i]), callback)) ownsCallback = YES;
        }
        free(methods);
        // class_getInstanceMethod alone can pass for an inherited framework stub.
        check(ownsCallback, "own Objective-C preview callback");
        check(provider && class_getInstanceMethod(provider, callback) != NULL, "Objective-C callback lookup");
        fprintf(stdout, "Quick Look runtime probe: %u failure(s); Finder GUI not exercised\n", failures);
        fflush(stdout);
        _Exit(failures ? 1 : 0);
    }
}
