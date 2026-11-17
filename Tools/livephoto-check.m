#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <dlfcn.h>
#import <objc/message.h>
// Runs the system's own "settling effect" (wallpaper motion) analysis on a photo + movie pair, in this process.
int main(int argc, char **argv) { @autoreleasepool {
    for (NSString *f in @[@"PhotoImaging", @"MediaAnalysis"]) dlopen([[NSString stringWithFormat:@"/System/Library/PrivateFrameworks/%@.framework/%@", f, f] UTF8String], RTLD_NOW);
    NSArray *urls = @[[NSURL fileURLWithPath:@(argv[1])], [NSURL fileURLWithPath:@(argv[2])]];
    id svc = ((id(*)(id, SEL))objc_msgSend)(NSClassFromString(@"VCPMediaAnalysisService"), NSSelectorFromString(@"sharedAnalysisService"));
    __block BOOL done = NO;
    ((int(*)(id, SEL, unsigned long long, id, id, id, id))objc_msgSend)(svc, NSSelectorFromString(@"requestAnalysisTypes:forAssetWithResourceURLs:withOptions:progressHandler:andCompletionHandler:"),
        0x4000000000ULL, urls, @{@"InProcess": @YES, @"AllowOnDemand": @YES, @"UserInitiatedMode": @YES}, nil, ^(id results, NSError *err) {
            printf("RAW results %s\nerror %s\n", [[results description] UTF8String], [[err description] UTF8String]); done = YES; });
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:150];
    while (!done && [until timeIntervalSinceNow] > 0) [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    if (!done) printf("no answer in 150 s\n");
} return 0; }
