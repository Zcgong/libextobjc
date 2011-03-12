//
//  EXTPrototype.m
//  extobjc
//
//  Created by Justin Spahr-Summers on 2011-03-11.
//  Released into the public domain.
//

#import "EXTPrototype.h"
#import "EXTBlockMethod.h"
#import "EXTRuntimeExtensions.h"
#import "NSMethodSignature+EXT.h"
#import <assert.h>
#import <ctype.h>

// doesn't include 'self' and '_cmd'
static
size_t argumentCountForSelectorName (const char *name) {
	size_t nameLength = strlen(name);
	size_t argCount = 0;

	// assume that the very first character won't be a colon
	NSCAssert(name[0] != ':', @"expected method name to start with something other than a colon");

	// and start on the second
	for (size_t i = 1;i < nameLength;++i) {
		if (name[i] == ':')
			++argCount;
	}

	return argCount;
}

static
BOOL nameIsSetter (const char *name) {
	return strncmp(name, "set", 3) == 0 && isupper(name[3]);
}

static
char *newTypeStringForArgumentCount (size_t argCount) {
	const char *idType = @encode(id);
	size_t idLen = strlen(idType);

	const char *selType = @encode(SEL);
	size_t selLen = strlen(selType);

	                       // id (*)  (id,    SEL,     ...)
	size_t typeStringLength = idLen + idLen + selLen + idLen * argCount;
	char *typeString = malloc(typeStringLength + 1);

	strncpy(typeString, idType, idLen);
	strncpy(typeString + idLen, idType, idLen);
	strncpy(typeString + idLen * 2, selType, selLen);

	char *moving = typeString + idLen * 2 + selLen;
	for (size_t i = 0;i < argCount;++i) {
		strncpy(moving, idType, idLen);
		moving += idLen;
	}

	*moving = '\0';
	return typeString;
}

static
id *copyParents (CFDictionaryRef dict, size_t *outCount) {
	size_t totalParents = 0;

	CFIndex count = CFDictionaryGetCount(dict);
	const void *values[count];

	{
		const void *keys[count];

		CFDictionaryGetKeysAndValues(
			dict,
			keys,
			values
		);

		for (CFIndex i = 0;i < count;++i) {
			CFStringRef key = keys[i];
			if (CFStringHasPrefix(key, CFSTR("parent")))
				++totalParents;
			else
				values[i] = NULL;
		}
	}

	id *parents = malloc((totalParents + 1) * sizeof(id));
	
	// use this to keep track of how many we actually fill in (we may not fill
	// in some because they turn out to not actually be proto-objects)
	totalParents = 0;
	for (CFIndex i = 0;i < count;++i) {
		id value = values[i];
		if ([value isKindOfClass:[EXTPrototype class]])
			parents[totalParents++] = value;
	}

	// NULL-terminate
	parents[totalParents] = NULL;

	if (outCount)
		*outCount = totalParents;

	return parents;
}

static
void invokeBlockMethodWithSelf (NSInvocation *invocation, id self) {
	NSMethodSignature *signature = [invocation methodSignature];

	NSLog(@"%s", __func__);
	NSLog(@"selector: %s", sel_getName([invocation selector]));
	NSLog(@"signature type: %s", [signature typeEncoding]);

	// add a faked 'id self' argument
	NSMethodSignature *newSignature = [signature methodSignatureByInsertingType:@encode(id) atArgumentIndex:2];
	NSInvocation *newInvocation = [NSInvocation invocationWithMethodSignature:newSignature];

	NSLog(@"new signature type: %s", [newSignature typeEncoding]);

	[newInvocation setTarget:[invocation target]];
	[newInvocation setSelector:[invocation selector]];
	[newInvocation setArgument:&self atIndex:2];

	NSUInteger origArgumentCount = [signature numberOfArguments];
	NSCAssert(origArgumentCount + 1 == [newSignature numberOfArguments], @"expected method signature and modified method signature to differ only in one argument");

	if (origArgumentCount > 2) {
		char buffer[[signature frameLength]];

		for (NSUInteger i = 2;i < origArgumentCount;++i) {
			NSLog(@"copying argument %lu", (unsigned long)i);
			[invocation getArgument:buffer atIndex:i];
			[newInvocation setArgument:buffer atIndex:i + 1];
		}
	}

	NSLog(@"%s:%lu", __func__, (unsigned long)__LINE__);
	NSLog(@"about to invoke against %p (%@)", (void *)self, [self class]);
	[newInvocation invoke];
	
	NSLog(@"%s:%lu", __func__, (unsigned long)__LINE__);
	NSCAssert([signature methodReturnLength] == [newSignature methodReturnLength], @"expected method signature and modified method signature to have the same return type");
	NSLog(@"%s:%lu", __func__, (unsigned long)__LINE__);

	if ([signature methodReturnLength]) {
		char returnValue[[signature methodReturnLength]];
		[newInvocation getReturnValue:returnValue];
		[invocation setReturnValue:returnValue];
	}

	NSLog(@"%s:%lu", __func__, (unsigned long)__LINE__);
}

@interface EXTPrototype () {
    CFMutableDictionaryRef slots;
	Class uniqueClass;
}

- (BOOL)respondToInvocationWithSlot:(NSInvocation *)anInvocation;
@end

@implementation EXTPrototype
// useful method signatures
+ (void)setSlot:(id)obj {}
+ (void)setSlot:(id)obj argumentCount:(int)count {}

#pragma mark Object lifecycle

+ (Class)uniqueClass {
	NSString *uniqueClassName = [[NSProcessInfo processInfo] globallyUniqueString];
	uniqueClassName = [@"EXTPrototypeStub_" stringByAppendingString:uniqueClassName];

	Class newClass = objc_allocateClassPair(
		self,
		[uniqueClassName UTF8String],
		0
	);

	if (!newClass) {
		return nil;
	}

	objc_registerClassPair(newClass);
	return newClass;
}

+ (id)prototype {
	EXTPrototype *obj = [[[self alloc] init] autorelease];

	obj->uniqueClass = [self uniqueClass];
	obj->slots = CFDictionaryCreateMutable(
		NULL,
		0,
		&kCFCopyStringDictionaryKeyCallBacks,
		&kCFTypeDictionaryValueCallBacks
	);

	return obj;
}

- (void)dealloc {
	if (slots) {
		CFRelease(slots);
		slots = NULL;
	}

	[super dealloc];
}

#pragma mark NSCopying

- (id)copyWithZone:(NSZone *)zone {
	EXTPrototype *obj = [[[self class] allocWithZone:zone] init];
	obj->uniqueClass = [EXTPrototype uniqueClass];
	obj->slots = CFDictionaryCreateMutableCopy(
		NULL,
		0,
		slots
	);

	return obj;
}

#pragma mark Public slot management

- (void)invokeSlot:(NSString *)slotName withInvocation:(NSInvocation *)invocation {
	NSUInteger argCount = [[invocation methodSignature] numberOfArguments] - 2;

	// include a faked 'self' argument
	NSUInteger slotLength = [slotName length];

	size_t methodNameLength = slotLength + argCount + 1;
	char methodName[methodNameLength + 1];

	CFStringGetCString(
		(CFStringRef)slotName,
		methodName,
		slotLength + 1,
		kCFStringEncodingUTF8
	);

	for (size_t i = slotLength;i < methodNameLength;++i) {
		methodName[i] = ':';
	}

	methodName[methodNameLength] = '\0';
	NSLog(@"methodName: %s", methodName);

	[invocation setSelector:sel_registerName(methodName)];
	[invocation setTarget:uniqueClass];

	invokeBlockMethodWithSelf(invocation, self);
}

- (void)setBlock:(id)block forSlot:(NSString *)slotName
  argumentCount:(NSUInteger)argCount {
	// create copies of blocks
	id slotValue = [block copy];
	NSLog(@"%@ is a block", (id)slotValue);

	CFDictionarySetValue(
		slots,
		(CFStringRef)slotName,
		slotValue
	);

	char * restrict typeString = newTypeStringForArgumentCount(argCount);
	NSLog(@"typeString: %s", typeString);

	NSUInteger slotLength = [slotName length];

	size_t methodNameLength = slotLength + argCount;
	char methodName[methodNameLength + 1];

	CFStringGetCString(
		(CFStringRef)slotName,
		methodName,
		slotLength + 1,
		kCFStringEncodingUTF8
	);

	for (size_t i = slotLength;i < methodNameLength;++i) {
		methodName[i] = ':';
	}

	methodName[methodNameLength] = '\0';
	NSLog(@"methodName: %s", methodName);

	// add the block as a class method
	ext_replaceBlockMethod(
		object_getClass(uniqueClass),
		sel_registerName(methodName),
		slotValue,
		typeString
	);

	free(typeString);

	[slotValue release];
}

- (void)setValue:(id)slotValue forSlot:(NSString *)slotName {
	Class blockClass = objc_getClass("NSBlock");

	if ([slotValue isKindOfClass:blockClass]) {
		[self setBlock:slotValue forSlot:slotName argumentCount:1];
		return;
	}

	id existingValue = (id)CFDictionaryGetValue(slots, (CFStringRef)slotName);

	if (slotValue) {
		CFDictionarySetValue(
			slots,
			(CFStringRef)slotName,
			slotValue
		);
	} else {
		CFDictionaryRemoveValue(slots, (CFStringRef)slotName);
	}

	NSLog(@"slots: %@", (id)slots);
	
	if ([existingValue isKindOfClass:blockClass]) {
		NSLog(@"%@ was a block", (id)existingValue);

		// remove the block as a class method
		ext_removeMethod(object_getClass(uniqueClass), NSSelectorFromString(slotName));
	} else {
		NSLog(@"using simple slot assignment for %@ replacing %@", (id)slotValue, (id)existingValue);
	}
}

- (id)valueForSlot:(NSString *)slotName {
	return (id)CFDictionaryGetValue(slots, (CFStringRef)slotName);
}

#pragma mark Forwarding machinery

- (void)forwardInvocation:(NSInvocation *)anInvocation {
	NSLog(@"%s", __func__);
	NSLog(@"selector: %s", sel_getName([anInvocation selector]));
	NSLog(@"signature type: %s", [[anInvocation methodSignature] typeEncoding]);

	if (![self respondToInvocationWithSlot:anInvocation])
		[self doesNotRecognizeSelector:[anInvocation selector]];
}

- (BOOL)respondToInvocationWithSlot:(NSInvocation *)anInvocation {
	const char *name = sel_getName([anInvocation selector]);
	size_t argCount = argumentCountForSelectorName(name);

	Class blockClass = objc_getClass("NSBlock");

	NSLog(@"slots: %@", (id)slots);

	const char *firstArg = strchr(name, ':');
	size_t slotLength;
	
	if (firstArg) {
		slotLength = firstArg - name;
		NSAssert(slotLength != 0, @"expected method name containing colon to also have an identifier");
	} else
		slotLength = strlen(name);

	CFStringRef slotKey = CFStringCreateWithBytes(
		NULL,
		(void *)name,
		slotLength,
		kCFStringEncodingUTF8,
		false
	);

	NSLog(@"slotKey: %@", (id)slotKey);

	id slotValue = [self valueForSlot:(id)slotKey];
	BOOL success = NO;

	if ([slotValue isKindOfClass:blockClass]) {
		[self invokeSlot:(id)slotKey withInvocation:anInvocation];
		success = YES;
	}

	CFRelease(slotKey);

	NSLog(@"slotValue: %@", slotValue);
	NSLog(@"[slotValue class]: %@", [slotValue class]);

	if (success) {
		return YES;
	} else if (argCount == 0) {
		[[slotValue retain] autorelease];
		[anInvocation setReturnValue:&slotValue];
		return YES;
	}

	// TODO: this should really check for method signatures here, not selector names
	BOOL isSetter = ((argCount == 1 || argCount == 2) && nameIsSetter(name));
	if (isSetter) {
		NSLog(@"%s determined to be a setter", name);

		slotLength -= 3;

		{
			char lowercaseSlot[slotLength];

			strncpy(lowercaseSlot, name + 3, slotLength);
			lowercaseSlot[0] = tolower(lowercaseSlot[0]);

			slotKey = CFStringCreateWithBytes(
				NULL,
				(void *)lowercaseSlot,
				slotLength,
				kCFStringEncodingUTF8,
				false
			);
		}

		NSLog(@"slotKey: %@", (id)slotKey);

		id slotValue = nil;
		[anInvocation getArgument:&slotValue atIndex:2];

		NSLog(@"slotValue: %@", (id)slotValue);

		if (argCount == 2) {
			int slotArgumentCount = 1;
			[anInvocation getArgument:&slotArgumentCount atIndex:3];

			[self setBlock:slotValue forSlot:(id)slotKey argumentCount:slotArgumentCount];
		} else {
			[self setValue:slotValue forSlot:(id)slotKey];
		}

		CFRelease(slotKey);
		return YES;
	}

	// try looking up in the parents of this prototype
	id *parents = copyParents(slots, NULL);

	if (parents) {
		while (*parents != NULL) {
			if ([*parents respondToInvocationWithSlot:anInvocation]) {
				success = YES;
				break;
			}
		}

		free(parents);
	}

	return success;
}

- (NSMethodSignature *)methodSignatureForSelector:(SEL)aSelector {
	NSLog(@"%s", __func__);
	NSLog(@"selector: %s", sel_getName(aSelector));

	NSMethodSignature *signature = [EXTPrototype instanceMethodSignatureForSelector:aSelector];
	if (signature) {
		NSLog(@"signature type: %s", [signature typeEncoding]);
		NSLog(@"number of args: %lu", (unsigned long)[signature numberOfArguments]);
		return signature;
	}
	
	const char *name = sel_getName(aSelector);

	size_t argCount = argumentCountForSelectorName(name);
	if (nameIsSetter(name)) {
		if (argCount == 1) {
			return [EXTPrototype methodSignatureForSelector:@selector(setSlot:)];
		} else if (argCount == 2) {
			return [EXTPrototype methodSignatureForSelector:@selector(setSlot:argumentCount:)];
		}
	}

	char * restrict typeString = newTypeStringForArgumentCount(argCount);
	NSLog(@"typeString: %s", typeString);

	signature = [NSMethodSignature signatureWithObjCTypes:typeString];
	free(typeString);

	NSLog(@"signature type: %s", [signature typeEncoding]);
	NSLog(@"number of args: %lu", (unsigned long)[signature numberOfArguments]);

	return signature;
}

#pragma mark NSObject protocol

- (NSUInteger)hash {
	return CFHash(slots);
}

- (BOOL)isEqual:(id)obj {
	if (![obj isKindOfClass:[EXTPrototype class]])
		return NO;

	EXTPrototype *proto = obj;
	return CFEqual(slots, proto->slots);
}

- (BOOL)respondsToSelector:(SEL)aSelector {
	// TODO: be more discriminating
	return YES;
}
@end
