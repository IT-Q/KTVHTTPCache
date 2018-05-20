//
//  KTVHCDataUnitPool.m
//  KTVHTTPCache
//
//  Created by Single on 2017/8/11.
//  Copyright © 2017年 Single. All rights reserved.
//

#import "KTVHCDataUnitPool.h"
#import "KTVHCDataUnitQueue.h"
#import "KTVHCDataPrivate.h"
#import "KTVHCPathTools.h"
#import "KTVHCURLTools.h"
#import "KTVHCLog.h"

@interface KTVHCDataUnitPool () <NSLocking, KTVHCDataUnitFileDelegate>

@property (nonatomic, strong) NSRecursiveLock * coreLock;
@property (nonatomic, strong) KTVHCDataUnitQueue * unitQueue;

@end

@implementation KTVHCDataUnitPool

+ (instancetype)pool
{
    static KTVHCDataUnitPool * obj = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        obj = [[self alloc] init];
    });
    return obj;
}

- (instancetype)init
{
    if (self = [super init])
    {
        self.unitQueue = [KTVHCDataUnitQueue unitQueueWithArchiverPath:[KTVHCPathTools absolutePathForArchiver]];
        [self.unitQueue.allUnits enumerateObjectsUsingBlock:^(KTVHCDataUnit * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
            obj.fileDelegate = self;
        }];
    }
    return self;
}

- (KTVHCDataUnit *)unitWithURLString:(NSString *)URLString
{
    if (URLString.length <= 0) {
        return nil;
    }
    [self lock];
    NSString * uniqueIdentifier = [KTVHCURLTools uniqueIdentifierWithURLString:URLString];
    KTVHCDataUnit * unit = [self.unitQueue unitWithUniqueIdentifier:uniqueIdentifier];
    if (!unit)
    {
        KTVHCLogDataUnitPool(@"new unit, %@", URLString);
        unit = [KTVHCDataUnit unitWithURLString:URLString];
        unit.fileDelegate = self;
        [self.unitQueue putUnit:unit];
        [self.unitQueue archive];
    }
    [self unlock];
    return unit;
}

- (long long)totalCacheLength
{
    [self lock];
    long long length = 0;
    NSArray <KTVHCDataUnit *> * units = [self.unitQueue allUnits];
    for (KTVHCDataUnit * obj in units)
    {
        [obj lock];
        length += obj.totalCacheLength;
        [obj unlock];
    }
    [self unlock];
    return length;
}

- (KTVHCDataCacheItem *)cacheItemWithURLString:(NSString *)URLString
{
    if (URLString.length <= 0) {
        return nil;
    }
    [self lock];
    KTVHCDataCacheItem * cacheItem = nil;
    NSString * uniqueIdentifier = [KTVHCURLTools uniqueIdentifierWithURLString:URLString];
    KTVHCDataUnit * obj = [self.unitQueue unitWithUniqueIdentifier:uniqueIdentifier];
    if (obj)
    {
        [obj lock];
        NSMutableArray * itemZones = [NSMutableArray array];
        for (KTVHCDataUnitItem * unitItem in obj.unitItems)
        {
            KTVHCDataCacheItemZone * itemZone = [KTVHCDataCacheItemZone itemZoneWithOffset:unitItem.offset
                                                                                    length:unitItem.length];
            [itemZones addObject:itemZone];
        }
        if (itemZones.count <= 0) {
            itemZones = nil;
        }
        cacheItem = [KTVHCDataCacheItem itemWithURLString:obj.URLString
                                              totalLength:obj.totalContentLength
                                              cacheLength:obj.totalCacheLength
                                              vaildLength:obj.totalValidCacheLength
                                                    zones:itemZones];
        [obj unlock];
    }
    [self unlock];
    return cacheItem;
}

- (NSArray <KTVHCDataCacheItem *> *)allCacheItem
{
    [self lock];
    NSMutableArray * cacheItems = [NSMutableArray array];
    NSArray <KTVHCDataUnit *> * units = [self.unitQueue allUnits];
    for (KTVHCDataUnit * obj in units)
    {
        KTVHCDataCacheItem * cacheItem = [self cacheItemWithURLString:obj.URLString];
        if (cacheItem) {
            [cacheItems addObject:cacheItem];
        }
    }
    if (cacheItems.count <= 0) {
        cacheItems = nil;
    }
    [self unlock];
    return cacheItems;
}

- (void)deleteUnitWithURLString:(NSString *)URLString
{
    if (URLString.length <= 0) {
        return;
    }
    [self lock];
    NSString * uniqueIdentifier = [KTVHCURLTools uniqueIdentifierWithURLString:URLString];
    KTVHCDataUnit * obj = [self.unitQueue unitWithUniqueIdentifier:uniqueIdentifier];
    if (obj && !obj.working)
    {
        KTVHCLogDataUnit(@"delete unit 1, %@", URLString);
        
        [obj lock];
        [obj deleteFiles];
        [self.unitQueue popUnit:obj];
        [self.unitQueue archive];
        [obj unlock];
    }
    [self unlock];
}

- (void)deleteUnitsWithMinSize:(long long)minSize
{
    if (minSize <= 0) {
        return;
    }
    
    [self lock];
    
    BOOL needArchive = NO;
    long long currentSize = 0;
    
    NSArray <KTVHCDataUnit *> * units = [self.unitQueue allUnits];
    
#if 1
    [units sortedArrayUsingComparator:^NSComparisonResult(KTVHCDataUnit * obj1, KTVHCDataUnit * obj2) {
        NSComparisonResult result = NSOrderedDescending;
        [obj1 lock];
        [obj2 lock];
        NSTimeInterval timeInterval1 = obj1.lastItemCreateInterval;
        NSTimeInterval timeInterval2 = obj2.lastItemCreateInterval;
        if (timeInterval1 < timeInterval2) {
            result = NSOrderedAscending;
        } else if (timeInterval1 == timeInterval2 && obj1.createTimeInterval < obj2.createTimeInterval) {
            result = NSOrderedAscending;
        }
        [obj1 unlock];
        [obj2 unlock];
        return result;
    }];
#endif
    
    for (KTVHCDataUnit * obj in units)
    {
        if (!obj.working)
        {
            KTVHCLogDataUnitPool(@"delete unit 2, %@", obj.URLString);
         
            [obj lock];
            currentSize += obj.totalCacheLength;
            [obj deleteFiles];
            [self.unitQueue popUnit:obj];
            needArchive = YES;
            [obj unlock];
        }
        if (currentSize >= minSize)
        {
            break;
        }
    }
    if (needArchive) {
        [self.unitQueue archive];
    }
    [self unlock];
}

- (void)deleteAllUnits
{
    [self lock];
    BOOL needArchive = NO;
    NSArray <KTVHCDataUnit *> * units = [self.unitQueue allUnits];
    for (KTVHCDataUnit * obj in units)
    {
        if (!obj.working)
        {
            KTVHCLogDataUnitPool(@"delete unit 2, %@", obj.URLString);
            
            [obj lock];
            [obj deleteFiles];
            [self.unitQueue popUnit:obj];
            needArchive = YES;
            [obj unlock];
        }
    }
    if (needArchive) {
        [self.unitQueue archive];
    }
    [self unlock];
}


#pragma mark - KTVHCDataUnitFileDelegate

- (void)unitShouldRearchive:(KTVHCDataUnit *)unit
{
    [self lock];
    [self.unitQueue archive];
    [self unlock];
}


#pragma mark - NSLocking

- (void)lock
{
    if (!self.coreLock) {
        self.coreLock = [[NSRecursiveLock alloc] init];
    }
    [self.coreLock lock];
}

- (void)unlock
{
    [self.coreLock unlock];
}


@end
