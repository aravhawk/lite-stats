//
//  reader.m
//  Sensors
//
//  Created by Serhiy Mytrovtsiy on 06/05/2021.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2021 Serhiy Mytrovtsiy. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "bridge.h"

// The event system client, its matched services and their names are resolved once per (page, usage) and reused,
// creating a client on every read is far more expensive than reading the events themselves.
NSDictionary*AppleSiliconSensors(int32_t page, int32_t usage, int32_t type) {
    static NSMutableDictionary<NSNumber*, NSArray*> *cache = nil;
    if (cache == nil) {
        cache = [NSMutableDictionary dictionary];
    }
    
    NSNumber *cacheKey = @(((int64_t)page << 32) | (uint32_t)usage);
    NSArray *entry = cache[cacheKey];
    if (entry == nil) {
        IOHIDEventSystemClientRef system = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (system == nil) {
            return nil;
        }
        NSDictionary *matching = @{@"PrimaryUsagePage":@(page),@"PrimaryUsage":@(usage)};
        IOHIDEventSystemClientSetMatching(system, (__bridge CFDictionaryRef)matching);
        NSArray *all = CFBridgingRelease(IOHIDEventSystemClientCopyServices(system)) ?: @[];
        
        NSMutableArray *services = [NSMutableArray array];
        NSMutableArray *names = [NSMutableArray array];
        for (id item in all) {
            NSString *name = CFBridgingRelease(IOHIDServiceClientCopyProperty((__bridge IOHIDServiceClientRef)item, CFSTR("Product")));
            if (name) {
                [services addObject:item];
                [names addObject:name];
            }
        }
        // the client is kept in the cache to stay alive as long as its services are used
        entry = @[(__bridge_transfer id)system, services, names];
        cache[cacheKey] = entry;
    }
    
    NSArray *services = entry[1];
    NSArray *names = entry[2];
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithCapacity:services.count];
    for (NSUInteger i = 0; i < services.count; i++) {
        IOHIDEventRef event = IOHIDServiceClientCopyEvent((__bridge IOHIDServiceClientRef)services[i], type, 0, 0);
        if (event == nil) {
            continue;
        }
        dict[names[i]] = @(IOHIDEventGetFloatValue(event, IOHIDEventFieldBase(type)));
        CFRelease(event);
    }
    
    return dict;
}
