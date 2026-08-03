//
//  HWGIconOverrideStore.m
//  HardwareGrowler
//

// compile with ARC: -fobjc-arc
#import "HWGIconOverrideStore.h"

static const CGFloat kHWGIconOverrideCanvasSize = 512.0;
static const CGFloat kHWGIconOverrideCoverage = 0.94; // matches the app's existing icon standard

@interface HWGIconOverrideStore ()
@property (nonatomic, strong) NSMutableSet<NSString *> *overriddenNames; // in-memory index, mirrors disk
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSImage *> *decodedImageCache; // avoids re-reading/decoding the PNG on every call
@property (nonatomic, strong) dispatch_queue_t queue;
@end

@implementation HWGIconOverrideStore

+ (instancetype)sharedStore {
	static HWGIconOverrideStore *shared = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{ shared = [[self alloc] init]; });
	return shared;
}

- (instancetype)init {
	self = [super init];
	if (self) {
		self.queue = dispatch_queue_create("com.jensyleo.hg4mac.iconoverrides", DISPATCH_QUEUE_SERIAL);
		self.overriddenNames = [[self loadIndexFromDisk] mutableCopy] ?: [NSMutableSet set];
		self.decodedImageCache = [NSMutableDictionary dictionary];
	}
	return self;
}

#pragma mark Paths

- (NSURL *)storeDirectory {
	NSURL *appSupport = [[NSFileManager defaultManager] URLForDirectory:NSApplicationSupportDirectory
																 inDomain:NSUserDomainMask
														appropriateForURL:nil
																   create:YES
																	error:nil];
	NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"com.jensyleo.hg4mac";
	NSURL *dir = [appSupport URLByAppendingPathComponent:bundleID];
	dir = [dir URLByAppendingPathComponent:@"IconOverrides"];
	[[NSFileManager defaultManager] createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];
	return dir;
}

- (NSURL *)indexFileURL {
	return [[self storeDirectory] URLByAppendingPathComponent:@"index.json"];
}

- (NSURL *)imageFileURLForDefaultName:(NSString *)defaultName {
	// Default icon names are already filesystem-safe (letters/digits/dashes only).
	NSString *fileName = [NSString stringWithFormat:@"%@.png", defaultName];
	return [[self storeDirectory] URLByAppendingPathComponent:fileName];
}

#pragma mark Index persistence

- (NSSet<NSString *> *)loadIndexFromDisk {
	NSData *data = [NSData dataWithContentsOfURL:[self indexFileURL]];
	if (!data) return nil;
	NSArray *raw = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
	if (![raw isKindOfClass:[NSArray class]]) return nil;
	return [NSSet setWithArray:raw];
}

// Must be called on self.queue.
- (void)persistIndex {
	NSData *data = [NSJSONSerialization dataWithJSONObject:[self.overriddenNames allObjects] options:0 error:nil];
	if (data) [data writeToURL:[self indexFileURL] atomically:YES];
}

#pragma mark Normalization

// Uniform bounding-box rescale to ~94% of the canvas, centered, transparent padding —
// same standard used for every hand-designed icon this session (never distorts aspect ratio).
- (NSImage *)normalizedImage:(NSImage *)source {
	NSSize sourceSize = source.size;
	if (sourceSize.width <= 0 || sourceSize.height <= 0) return source;

	CGFloat targetSpan = kHWGIconOverrideCanvasSize * kHWGIconOverrideCoverage;
	CGFloat scale = MIN(targetSpan / sourceSize.width, targetSpan / sourceSize.height);
	NSSize drawSize = NSMakeSize(sourceSize.width * scale, sourceSize.height * scale);
	NSPoint origin = NSMakePoint((kHWGIconOverrideCanvasSize - drawSize.width) / 2.0,
								  (kHWGIconOverrideCanvasSize - drawSize.height) / 2.0);

	NSImage *canvas = [[NSImage alloc] initWithSize:NSMakeSize(kHWGIconOverrideCanvasSize, kHWGIconOverrideCanvasSize)];
	[canvas lockFocus];
	[source drawInRect:NSMakeRect(origin.x, origin.y, drawSize.width, drawSize.height)
			  fromRect:NSZeroRect
			 operation:NSCompositingOperationSourceOver
			  fraction:1.0];
	[canvas unlockFocus];
	return canvas;
}

- (NSData *)pngDataForImage:(NSImage *)image {
	CGImageRef cgImage = [image CGImageForProposedRect:NULL context:nil hints:nil];
	if (!cgImage) return nil;
	NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithCGImage:cgImage];
	return [rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
}

#pragma mark Public API

- (void)setOverrideImage:(NSImage *)image forDefaultName:(NSString *)defaultName {
	if (![defaultName length] || !image) return;
	NSImage *normalized = [self normalizedImage:image];
	NSData *pngData = [self pngDataForImage:normalized];
	if (!pngData) return;

	dispatch_async(self.queue, ^{
		[pngData writeToURL:[self imageFileURLForDefaultName:defaultName] atomically:YES];
		[self.overriddenNames addObject:defaultName];
		self.decodedImageCache[defaultName] = normalized;
		[self persistIndex];
	});
}

- (void)removeOverrideForDefaultName:(NSString *)defaultName {
	if (![defaultName length]) return;
	dispatch_async(self.queue, ^{
		[[NSFileManager defaultManager] removeItemAtURL:[self imageFileURLForDefaultName:defaultName] error:nil];
		[self.overriddenNames removeObject:defaultName];
		[self.decodedImageCache removeObjectForKey:defaultName];
		[self persistIndex];
	});
}

- (BOOL)hasOverrideForDefaultName:(NSString *)defaultName {
	if (![defaultName length]) return NO;
	__block BOOL result = NO;
	dispatch_sync(self.queue, ^{
		result = [self.overriddenNames containsObject:defaultName];
	});
	return result;
}

- (NSImage *)overrideImageForDefaultName:(NSString *)defaultName {
	if (![defaultName length]) return nil;
	__block NSImage *result = nil;
	__block BOOL needsDecode = NO;
	dispatch_sync(self.queue, ^{
		if (![self.overriddenNames containsObject:defaultName]) return;
		result = self.decodedImageCache[defaultName];
		needsDecode = (result == nil);
	});
	if (!needsDecode) return result;

	// Decode off the queue (disk I/O + PNG decode shouldn't block other override lookups),
	// then cache the result on the queue.
	NSImage *decoded = [[NSImage alloc] initWithContentsOfURL:[self imageFileURLForDefaultName:defaultName]];
	if (decoded) {
		dispatch_async(self.queue, ^{
			self.decodedImageCache[defaultName] = decoded;
		});
	}
	return decoded;
}

#pragma mark Public accessors for the combined settings-profile flow

- (NSURL *)overridesDirectoryURL {
	return [self storeDirectory];
}

- (void)reloadFromDisk {
	dispatch_sync(self.queue, ^{
		self.overriddenNames = [[self loadIndexFromDisk] mutableCopy] ?: [NSMutableSet set];
		[self.decodedImageCache removeAllObjects];
	});
}

@end

NSImage *HWGResolveIconNamed(NSString *defaultName) {
	if (![defaultName length]) return nil;
	NSImage *override = [[HWGIconOverrideStore sharedStore] overrideImageForDefaultName:defaultName];
	return override ?: [NSImage imageNamed:defaultName];
}
