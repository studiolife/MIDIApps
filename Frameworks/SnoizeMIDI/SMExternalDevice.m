//
// Copyright 2002 Kurt Revis. All rights reserved.
//

#import "SMExternalDevice.h"
#import "SMClient.h"


/* TODO all this should be obsolete
@interface SMExternalDevice (Private)

+ (void)reloadExternalDevices;

@end
*/


@implementation SMExternalDevice

//
// SMMIDIObject requires that we subclass these methods:
//

+ (MIDIObjectType)midiObjectType;
{
    return kMIDIObjectType_ExternalDevice;
}

+ (ItemCount)midiObjectCount;
{
    return MIDIGetNumberOfExternalDevices();
}

+ (MIDIObjectRef)midiObjectAtIndex:(ItemCount)index;
{
    return (MIDIObjectRef)MIDIGetExternalDevice(index);
}

//
// New methods
//

+ (NSArray *)externalDevices;
{
    return [self allObjectsInOrder];
}

+ (SMExternalDevice *)externalDeviceWithUniqueID:(MIDIUniqueID)aUniqueID;
{
    return (SMExternalDevice *)[self objectWithUniqueID:aUniqueID];
}

+ (SMExternalDevice *)externalDeviceWithDeviceRef:(MIDIDeviceRef)aDeviceRef;
{
    return (SMExternalDevice *)[self objectWithObjectRef:(MIDIObjectRef)aDeviceRef];
}

- (MIDIDeviceRef)deviceRef;
{
    return (MIDIDeviceRef)objectRef;
}

- (NSString *)manufacturerName;
{
    return [self stringForProperty:kMIDIPropertyManufacturer];
}

- (NSString *)modelName;
{
    return [self stringForProperty:kMIDIPropertyModel];
}

- (NSString *)pathToImageFile;
#if MAC_OS_X_VERSION_MIN_REQUIRED >= MAC_OS_X_VERSION_10_2
{
    return [self stringForProperty:kMIDIPropertyImage];
}
#else
{
    // NOTE CoreMIDI's symbol kMIDIPropertyImage is new to 10.2, but we can't link against it directly
    // because that will cause us to fail to run on 10.1. So, instead, we try to look up the address of
    // the symbol at runtime and use it if we find it.

    CFStringRef propertyName;

    propertyName = [[SMClient sharedClient] coreMIDIPropertyNameConstantNamed:@"kMIDIPropertyImage"];
    if (propertyName)
        return [self stringForProperty:(CFStringRef)propertyName];
    else
        return nil;
}
#endif

@end


/* TODO all this should be obsolete
@implementation SMExternalDevice (Private)

+ (void)reloadExternalDevices
{
    NSMapTable *oldMapTable, *newMapTable;
    ItemCount extDeviceCount, extDeviceIndex;
    NSMutableArray *removedDevices, *replacedDevices, *replacementDevices, *addedDevices;

    extDeviceCount = MIDIGetNumberOfExternalDevices();

    oldMapTable = staticExternalDevicesMapTable;
    newMapTable = NSCreateMapTable(NSNonOwnedPointerMapKeyCallBacks, NSObjectMapValueCallBacks, extDeviceCount);

    // We start out assuming all external devices have been removed, and none have been replaced.
    // As we find out otherwise, we remove some devices from removedDevices, and add some
    // to replacedDevices.
    removedDevices = [NSMutableArray arrayWithArray:[self externalDevices]];
    replacedDevices = [NSMutableArray array];
    replacementDevices = [NSMutableArray array];
    addedDevices = [NSMutableArray array];

    // Iterate through the new list of external devices.
    for (extDeviceIndex = 0; extDeviceIndex < extDeviceCount; extDeviceIndex++) {
        MIDIDeviceRef aDeviceRef;
        SMExternalDevice *extDevice;

        aDeviceRef = MIDIGetExternalDevice(extDeviceIndex);
        if (aDeviceRef == NULL)
            continue;

        if ((extDevice = [self externalDeviceWithDeviceRef:aDeviceRef])) {
            // This device existed previously.
            [removedDevices removeObjectIdenticalTo:extDevice];
            // It's possible that its uniqueID changed, though.
            [extDevice updateUniqueID];
            // And its ordinal may also have changed...
            [extDevice setOrdinal:extDeviceIndex];
        } else {
            SMExternalDevice *replacedDevice;

            // This MIDIDeviceRef did not previously exist, so create a new ext. device for it.
            extDevice = [[[self alloc] initWithDeviceRef:aDeviceRef] autorelease];
            [extDevice setOrdinal:extDeviceIndex];

            // If the new ext. device has the same uniqueID as an old ext. device, remember it.
            if ((replacedDevice = [self externalDeviceWithUniqueID:[extDevice uniqueID]])) {
                [replacedDevices addObject:replacedDevice];
                [replacementDevices addObject:extDevice];
                [removedDevices removeObjectIdenticalTo:replacedDevice];
            } else {
                [addedDevices addObject:extDevice];
            }
        }

        NSMapInsert(newMapTable, aDeviceRef, extDevice);
    }

    if (oldMapTable)
        NSFreeMapTable(oldMapTable);
    staticExternalDevicesMapTable = newMapTable;

    // TODO post notifications etc (see SMEndpoint version)
}

@end
*/