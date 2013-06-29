//
//  NSObject+BlockObservation.m
//  BlocksKit
//

#import "NSObject+BlockObservation.h"
#import "NSObject+AssociatedObjects.h"
#import "NSDictionary+BlocksKit.h"
#import "NSArray+BlocksKit.h"
#import "NSSet+BlocksKit.h"
#import <objc/runtime.h>

typedef NS_ENUM(int, BKObserverContext) {
	BKObserverContextKey,
	BKObserverContextKeyWithChange,
	BKObserverContextManyKeys,
	BKObserverContextManyKeysWithChange
};

@interface BKObserver : NSObject

@property (nonatomic, readonly, unsafe_unretained) id observee;
@property (nonatomic, readonly) NSMutableArray *keyPaths;
@property (nonatomic, readonly) id task;
@property (nonatomic, readonly) BKObserverContext context;

- (id)initWithObservee:(id)observee keyPaths:(NSArray *)keyPaths options:(NSKeyValueObservingOptions)options context:(BKObserverContext)context task:(id)task;

@end

static char kObserverBlocksKey;
static char BKBlockObservationContext;

@implementation BKObserver

- (id)initWithObservee:(id)observee keyPaths:(NSArray *)keyPaths options:(NSKeyValueObservingOptions)options context:(BKObserverContext)context task:(id)task
{
	if ((self = [super init])) {
		_observee = observee;
		_keyPaths = [keyPaths mutableCopy];
		_context = context;
		_task = [task copy];
		[self startObservingWithOptions:options];
	}
	return self;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	if (context != &BKBlockObservationContext) return;
	
	@synchronized(self) {
		switch (self.context) {
			case BKObserverContextKey: {
				void (^task)(id) = self.task;
				task(object);
				break;
			}
			case BKObserverContextKeyWithChange: {
				void (^task)(id, NSDictionary *) = self.task;
				task(object, change);
				break;
			}
			case BKObserverContextManyKeys: {
				void (^task)(id, NSString *) = self.task;
				task(object, keyPath);
				break;
			}
			case BKObserverContextManyKeysWithChange: {
				void (^task)(id, NSString *, NSDictionary *) = self.task;
				task(object, keyPath, change);
				break;
			}
		}
	}
}

- (void)startObservingWithOptions:(NSKeyValueObservingOptions)options
{
	[self.keyPaths bk_each:^(NSString *keyPath) {
		[self.observee addObserver:self forKeyPath:keyPath options:options context:&BKBlockObservationContext];
	}];
}

- (void)stopObservingKeyPath:(NSString *)keyPath
{
	NSParameterAssert(keyPath);
	
	NSObject *observee;
	
	@synchronized (self) {
		if (![self.keyPaths containsObject:keyPath]) return;
		
		observee = self.observee;
		if (!observee) return;
		
		[self.keyPaths removeObject: keyPath];
		keyPath = [keyPath copy];
		
		if (!self.keyPaths.count) {
			_task = nil;
			_observee = nil;
			_keyPaths = nil;
		}
	}
	
	[observee removeObserver:self forKeyPath:keyPath context:&BKBlockObservationContext];
}

- (void)stopObserving
{
	if (_observee == nil) return;
	NSObject *observee;
	NSArray *keyPaths;
	
	@synchronized (self) {
		_task = nil;
		
		observee = self.observee;
		keyPaths = [self.keyPaths copy];
		
		_observee = nil;
		_keyPaths = nil;
	}
	
	[keyPaths bk_each:^(NSString *keyPath) {
		[observee removeObserver:self forKeyPath:keyPath context:&BKBlockObservationContext];
	}];
}

- (void)dealloc
{
	[self stopObserving];
}

@end

static NSMutableSet *swizzledClasses()
{
	static dispatch_once_t onceToken;
	static NSMutableSet *swizzledClasses = nil;
	dispatch_once(&onceToken, ^{
		swizzledClasses = [[NSMutableSet alloc] init];
	});
	
	return swizzledClasses;
}

@implementation NSObject (BlockObservation)

- (NSString *)bk_addObserverForKeyPath:(NSString *)keyPath task:(void (^)(id target))task
{
	NSString *token = [[NSProcessInfo processInfo] globallyUniqueString];
	[self bk_addObserverForKeyPaths:@[ keyPath ] identifier:token options:0 context:BKObserverContextKey task:task];
	return token;
}

- (NSString *)bk_addObserverForKeyPaths:(NSArray *)keyPaths task:(void (^)(id obj, NSDictionary *keyPath))task
{
	NSString *token = [[NSProcessInfo processInfo] globallyUniqueString];
	[self bk_addObserverForKeyPaths:keyPaths identifier:token options:0 context:BKObserverContextManyKeys task:task];
	return token;
}

- (NSString *)bk_addObserverForKeyPath:(NSString *)keyPath options:(NSKeyValueObservingOptions)options task:(void (^)(id obj, NSDictionary *change))task
{
	NSString *token = [[NSProcessInfo processInfo] globallyUniqueString];
	[self bk_addObserverForKeyPath:keyPath identifier:token options:options task:task];
	return token;
}

- (NSString *)bk_addObserverForKeyPaths:(NSArray *)keyPaths options:(NSKeyValueObservingOptions)options task:(void (^)(id obj, NSString *keyPath, NSDictionary *change))task
{
	NSString *token = [[NSProcessInfo processInfo] globallyUniqueString];
	[self bk_addObserverForKeyPaths:keyPaths identifier:token options:options task:task];
	return token;
}

- (void)bk_addObserverForKeyPath:(NSString *)keyPath identifier:(NSString *)identifier options:(NSKeyValueObservingOptions)options task:(void (^)(id obj, NSDictionary *change))task
{
	BKObserverContext context = (options == 0) ? BKObserverContextKey : BKObserverContextKeyWithChange;
	[self bk_addObserverForKeyPaths:@[keyPath] identifier:identifier options:options context:context task:task];
}

- (void)bk_addObserverForKeyPaths:(NSArray *)keyPaths identifier:(NSString *)identifier options:(NSKeyValueObservingOptions)options task:(void (^)(id obj, NSString *keyPath, NSDictionary *change))task
{
	BKObserverContext context = (options == 0) ? BKObserverContextManyKeys : BKObserverContextManyKeysWithChange;
	[self bk_addObserverForKeyPaths:keyPaths identifier:identifier options:options context:context task:task];
}

- (void)bk_removeObserverForKeyPath:(NSString *)keyPath identifier:(NSString *)token
{
	NSParameterAssert(keyPath.length);
	NSParameterAssert(token.length);
	
	NSMutableDictionary *dict;
	
	@synchronized (self) {
		dict = [self bk_observerBlocks];
		if (!dict) return;
	}
	
	BKObserver *observer = dict[token];
	[observer stopObservingKeyPath:keyPath];
	
	if (observer.keyPaths.count == 0) {
		[dict removeObjectForKey:token];
	}
	
	if (dict.count == 0) [self bk_setObserverBlocks:nil];
}

- (void)bk_removeObserversWithIdentifier:(NSString *)token
{
	NSParameterAssert(token);
	
	NSMutableDictionary *dict;
	
	@synchronized (self) {
		dict = [self bk_observerBlocks];
		if (!dict) return;
	}

	BKObserver *observer = dict[token];
	[observer stopObserving];
	
	[dict removeObjectForKey:token];
	
	if (dict.count == 0) [self bk_setObserverBlocks:nil];
}

- (void)bk_removeAllBlockObservers
{
	NSDictionary *dict;
	
	@synchronized (self) {
		dict = [[self bk_observerBlocks] copy];
		[self bk_setObserverBlocks:nil];
	}
	
	[dict.allValues bk_each:^(BKObserver *trampoline) {
		[trampoline stopObserving];
	}];
}

#pragma mark - "Private"

- (void)bk_addObserverForKeyPaths:(NSArray *)keyPaths identifier:(NSString *)identifier options:(NSKeyValueObservingOptions)options context:(BKObserverContext)context task:(id)task
{
	NSParameterAssert(keyPaths.count);
	NSParameterAssert(identifier.length);
	NSParameterAssert(task);
	
	@synchronized (swizzledClasses()) {
		Class classToSwizzle = self.class;
		NSString *className = NSStringFromClass(classToSwizzle);
		if (![swizzledClasses() containsObject:className]) {
			SEL deallocSelector = sel_registerName("dealloc");
			
			Method deallocMethod = class_getInstanceMethod(classToSwizzle, deallocSelector);
			void (*originalDealloc)(id, SEL) = (__typeof__(originalDealloc))method_getImplementation(deallocMethod);
			
			id newDealloc = ^(__unsafe_unretained NSObject *objSelf) {
				[objSelf bk_removeAllBlockObservers];
				originalDealloc(objSelf, deallocSelector);
			};
			
			class_replaceMethod(classToSwizzle, deallocSelector, imp_implementationWithBlock(newDealloc), method_getTypeEncoding(deallocMethod));
			
			[swizzledClasses() addObject:className];
		}
	}
	
	NSMutableDictionary *dict;
	BKObserver *observer = [[BKObserver alloc] initWithObservee:self keyPaths:keyPaths options:options context:context task:task];
		
	@synchronized (self) {
		dict = [self bk_observerBlocks];
		
		if (dict == nil) {
			dict = [NSMutableDictionary dictionary];
			[self bk_setObserverBlocks:dict];
		}
	}
	
	dict[identifier] = observer;
}

- (void)bk_setObserverBlocks:(NSMutableDictionary *)dict
{
	[self bk_associateValue:dict withKey:&kObserverBlocksKey];
}

- (NSMutableDictionary *)bk_observerBlocks
{
	return [self bk_associatedValueForKey:&kObserverBlocksKey];
}

@end
