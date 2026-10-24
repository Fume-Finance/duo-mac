// Duo Mac Microphone: a virtual audio device that turns what Duo Mac plays into it (the iPhone's
// microphone, streamed over the network) into microphone input for every Mac app.
//
// A Core Audio "AudioServerPlugIn", loaded by coreaudiod from /Library/Audio/Plug-Ins/HAL. Two devices
// joined by a ring buffer, on one shared clock:
//   • "Duo Mac Microphone": input only, what apps record from.
//   • "Duo Mac Microphone Feed": output only and hidden, what Duo Mac plays into.
// Samples written to the feed at a given sample time are read back by the microphone a moment later
// (a loopback, like BlackHole). Two devices rather than one with both directions, because opening a
// device that has an input counts as using a microphone: macOS would stop Duo Mac to ask for
// permission just to play into it.
//
// Structure follows Apple's NullAudio sample driver. 48 kHz, mono, 32-bit float.

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>

#define kPlugInBundleID "com.riccardoconti.duomac.microphone"
#define kMicUID "DuoMacMicrophone_UID"
#define kFeedUID "DuoMacMicrophoneFeed_UID"
#define kModelUID "DuoMacMicrophone_ModelUID"

enum {
    kObjectID_PlugIn = kAudioObjectPlugInObject,
    kObjectID_Mic = 2,
    kObjectID_Mic_Stream = 3,
    kObjectID_Feed = 4,
    kObjectID_Feed_Stream = 5,
};

static const Float64 kSampleRate = 48000.0;
static const UInt32 kChannels = 1;
static const UInt32 kRingFrames = 16384;            // also the zero-time-stamp period (~0.34 s)
static const UInt32 kLatencyFrames = 0;
static const UInt32 kSafetyFrames = 0;
static const UInt32 kClockDomain = 0x44756f4d;      // 'DuoM': both devices run on the same clock

static AudioServerPlugInHostRef gHost = NULL;
static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32 gRefCount = 0;

static UInt32 gIOCount[2] = { 0, 0 };              // [0] the microphone, [1] the feed
static Float64 gHostTicksPerFrame = 0;
static UInt64 gAnchorHostTime = 0;                  // the shared clock's sample time 0
static bool gMicStreamActive = true, gFeedStreamActive = true;

static float gRing[16384];                           // kRingFrames × kChannels

// ───── Forward declarations of the interface ─────

static HRESULT DM_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG DM_AddRef(void* inDriver);
static ULONG DM_Release(void* inDriver);
static OSStatus DM_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus DM_CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo*, AudioObjectID*);
static OSStatus DM_DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);
static OSStatus DM_AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus DM_RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus DM_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static OSStatus DM_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static Boolean DM_HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*);
static OSStatus DM_IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, Boolean*);
static OSStatus DM_GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32*);
static OSStatus DM_GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, UInt32*, void*);
static OSStatus DM_SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, const void*);
static OSStatus DM_StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus DM_StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus DM_GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64*, UInt64*, UInt64*);
static OSStatus DM_WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, Boolean*, Boolean*);
static OSStatus DM_BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);
static OSStatus DM_DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*, void*, void*);
static OSStatus DM_EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    DM_QueryInterface, DM_AddRef, DM_Release,
    DM_Initialize, DM_CreateDevice, DM_DestroyDevice, DM_AddDeviceClient, DM_RemoveDeviceClient,
    DM_PerformDeviceConfigurationChange, DM_AbortDeviceConfigurationChange,
    DM_HasProperty, DM_IsPropertySettable, DM_GetPropertyDataSize, DM_GetPropertyData, DM_SetPropertyData,
    DM_StartIO, DM_StopIO, DM_GetZeroTimeStamp, DM_WillDoIOOperation, DM_BeginIOOperation, DM_DoIOOperation, DM_EndIOOperation,
};
static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

// ───── Factory (named in Info.plist) ─────

void* DuoMacMicrophone_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
void* DuoMacMicrophone_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;
    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) return gDriverRef;
    return NULL;
}

// ───── IUnknown ─────

static HRESULT DM_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface) {
    if (inDriver != gDriverRef || !outInterface) return kAudioHardwareIllegalOperationError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gStateMutex);
        gRefCount++;
        pthread_mutex_unlock(&gStateMutex);
        *outInterface = gDriverRef;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG DM_AddRef(void* inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    ULONG r = ++gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return r;
}

static ULONG DM_Release(void* inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount > 0) gRefCount--;
    ULONG r = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return r;
}

// ───── Basic operations ─────

static OSStatus DM_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = inHost;
    struct mach_timebase_info tb;
    mach_timebase_info(&tb);
    Float64 hostClockFrequency = ((Float64)tb.denom / (Float64)tb.numer) * 1000000000.0;
    gHostTicksPerFrame = hostClockFrequency / kSampleRate;
    gAnchorHostTime = mach_absolute_time();
    return 0;
}

static OSStatus DM_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo* c, AudioObjectID* out) {
    (void)d; (void)desc; (void)c; (void)out;
    return kAudioHardwareUnsupportedOperationError;
}
static OSStatus DM_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID id) { (void)d; (void)id; return kAudioHardwareUnsupportedOperationError; }
static OSStatus DM_AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo* c) { (void)d; (void)id; (void)c; return 0; }
static OSStatus DM_RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo* c) { (void)d; (void)id; (void)c; return 0; }
static OSStatus DM_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 a, void* i) { (void)d; (void)id; (void)a; (void)i; return 0; }
static OSStatus DM_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 a, void* i) { (void)d; (void)id; (void)a; (void)i; return 0; }

// ───── Helpers ─────

static AudioStreamBasicDescription StreamFormat(void) {
    AudioStreamBasicDescription f;
    memset(&f, 0, sizeof f);
    f.mSampleRate = kSampleRate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = 4 * kChannels;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = 4 * kChannels;
    f.mChannelsPerFrame = kChannels;
    f.mBitsPerChannel = 32;
    return f;
}

static bool IsDevice(AudioObjectID id) { return id == kObjectID_Mic || id == kObjectID_Feed; }
static bool IsStream(AudioObjectID id) { return id == kObjectID_Mic_Stream || id == kObjectID_Feed_Stream; }

/// Copies `value` (of `size` bytes) out, or fails if there's no room.
#define RETURN_VALUE(TYPE, VALUE) do { \
        if (inDataSize < sizeof(TYPE)) return kAudioHardwareBadPropertySizeError; \
        *(TYPE*)outData = (VALUE); *outDataSize = sizeof(TYPE); return 0; } while (0)

// ───── Properties ─────

static Boolean DM_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a) {
    (void)pid;
    if (inDriver != gDriverRef || !a) return false;
    switch (id) {
    case kObjectID_PlugIn:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects: case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice: case kAudioPlugInPropertyResourceBundle:
            return true;
        }
        return false;
    case kObjectID_Mic:
    case kObjectID_Feed:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer: case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyDeviceUID: case kAudioDevicePropertyModelUID: case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices: case kAudioDevicePropertyClockDomain: case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning: case kAudioObjectPropertyControlList: case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates: case kAudioDevicePropertyIsHidden: case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyStreams:
            return true;
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency: case kAudioDevicePropertySafetyOffset: case kAudioDevicePropertyPreferredChannelsForStereo:
        case kAudioDevicePropertyPreferredChannelLayout:
            return a->mScope == kAudioObjectPropertyScopeInput || a->mScope == kAudioObjectPropertyScopeOutput;
        }
        return false;
    case kObjectID_Mic_Stream:
    case kObjectID_Feed_Stream:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects: case kAudioStreamPropertyIsActive: case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType: case kAudioStreamPropertyStartingChannel: case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        }
        return false;
    }
    return false;
}

static OSStatus DM_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a, Boolean* out) {
    (void)pid;
    if (inDriver != gDriverRef || !a || !out) return kAudioHardwareIllegalOperationError;
    if (!DM_HasProperty(inDriver, id, pid, a)) return kAudioHardwareUnknownPropertyError;
    *out = false;
    if (IsDevice(id) && a->mSelector == kAudioDevicePropertyNominalSampleRate) *out = true;
    if (IsStream(id) && (a->mSelector == kAudioStreamPropertyIsActive || a->mSelector == kAudioStreamPropertyVirtualFormat
                         || a->mSelector == kAudioStreamPropertyPhysicalFormat)) *out = true;
    return 0;
}

static OSStatus DM_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a,
                                       UInt32 qSize, const void* q, UInt32* out) {
    (void)qSize; (void)q;
    if (inDriver != gDriverRef || !a || !out) return kAudioHardwareIllegalOperationError;
    if (!DM_HasProperty(inDriver, id, pid, a)) return kAudioHardwareUnknownPropertyError;
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: case kAudioObjectPropertyClass: case kAudioObjectPropertyOwner:
        *out = sizeof(AudioClassID); return 0;
    case kAudioObjectPropertyName: case kAudioObjectPropertyManufacturer: case kAudioDevicePropertyDeviceUID:
    case kAudioDevicePropertyModelUID: case kAudioPlugInPropertyResourceBundle:
        *out = sizeof(CFStringRef); return 0;
    case kAudioObjectPropertyControlList:
        *out = 0; return 0;
    case kAudioPlugInPropertyTranslateUIDToDevice:
        *out = sizeof(AudioObjectID); return 0;
    case kAudioDevicePropertyAvailableNominalSampleRates:
        *out = sizeof(AudioValueRange); return 0;
    case kAudioDevicePropertyNominalSampleRate:
        *out = sizeof(Float64); return 0;
    case kAudioDevicePropertyPreferredChannelsForStereo:
        *out = 2 * sizeof(UInt32); return 0;
    case kAudioDevicePropertyPreferredChannelLayout:
        *out = (UInt32)offsetof(AudioChannelLayout, mChannelDescriptions) + kChannels * sizeof(AudioChannelDescription); return 0;
    case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
        *out = sizeof(AudioStreamBasicDescription); return 0;
    case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats:
        *out = sizeof(AudioStreamRangedDescription); return 0;
    case kAudioObjectPropertyOwnedObjects:
        *out = (id == kObjectID_PlugIn ? 2 : IsDevice(id) ? 1 : 0) * sizeof(AudioObjectID);
        return 0;
    case kAudioPlugInPropertyDeviceList:
        *out = 2 * sizeof(AudioObjectID); return 0;
    case kAudioDevicePropertyRelatedDevices:
        *out = sizeof(AudioObjectID); return 0;
    case kAudioDevicePropertyStreams: {
        bool mic = id == kObjectID_Mic;
        bool none = (mic && a->mScope == kAudioObjectPropertyScopeOutput) || (!mic && a->mScope == kAudioObjectPropertyScopeInput);
        *out = (none ? 0 : 1) * sizeof(AudioObjectID); return 0;
    }
    default:
        *out = sizeof(UInt32); return 0;
    }
}

static OSStatus DM_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a,
                                   UInt32 qSize, const void* q, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    (void)pid;
    if (inDriver != gDriverRef || !a || !outDataSize || !outData) return kAudioHardwareIllegalOperationError;
    if (!DM_HasProperty(inDriver, id, pid, a)) return kAudioHardwareUnknownPropertyError;

    if (id == kObjectID_PlugIn) {
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: RETURN_VALUE(CFStringRef, CFSTR("Duo Mac"));
        case kAudioObjectPropertyOwnedObjects: case kAudioPlugInPropertyDeviceList: {
            AudioObjectID ids[2] = { kObjectID_Mic, kObjectID_Feed };
            UInt32 n = inDataSize / sizeof(AudioObjectID);
            if (n > 2) n = 2;
            memcpy(outData, ids, n * sizeof(AudioObjectID));
            *outDataSize = n * sizeof(AudioObjectID);
            return 0;
        }
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            AudioObjectID r = kAudioObjectUnknown;
            CFStringRef uid = (qSize == sizeof(CFStringRef) && q) ? *(CFStringRef*)q : NULL;
            if (uid && CFStringCompare(uid, CFSTR(kMicUID), 0) == kCFCompareEqualTo) r = kObjectID_Mic;
            if (uid && CFStringCompare(uid, CFSTR(kFeedUID), 0) == kCFCompareEqualTo) r = kObjectID_Feed;
            RETURN_VALUE(AudioObjectID, r);
        }
        case kAudioPlugInPropertyResourceBundle: RETURN_VALUE(CFStringRef, CFSTR(""));
        }
    } else if (IsDevice(id)) {
        bool mic = id == kObjectID_Mic;
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, kObjectID_PlugIn);
        case kAudioObjectPropertyName: RETURN_VALUE(CFStringRef, mic ? CFSTR("Duo Mac Microphone") : CFSTR("Duo Mac Microphone Feed"));
        case kAudioObjectPropertyManufacturer: RETURN_VALUE(CFStringRef, CFSTR("Duo Mac"));
        case kAudioDevicePropertyDeviceUID: RETURN_VALUE(CFStringRef, mic ? CFSTR(kMicUID) : CFSTR(kFeedUID));
        case kAudioDevicePropertyModelUID: RETURN_VALUE(CFStringRef, CFSTR(kModelUID));
        case kAudioDevicePropertyTransportType: RETURN_VALUE(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyRelatedDevices: RETURN_VALUE(AudioObjectID, id);
        case kAudioDevicePropertyClockDomain: RETURN_VALUE(UInt32, kClockDomain);
        case kAudioDevicePropertyDeviceIsAlive: RETURN_VALUE(UInt32, 1);
        case kAudioDevicePropertyDeviceIsRunning: {
            pthread_mutex_lock(&gStateMutex);
            UInt32 running = gIOCount[mic ? 0 : 1] > 0;
            pthread_mutex_unlock(&gStateMutex);
            RETURN_VALUE(UInt32, running);
        }
        // Only the microphone can be a default device (an input); the feed is for Duo Mac alone.
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: RETURN_VALUE(UInt32, mic && a->mScope == kAudioObjectPropertyScopeInput);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyLatency: RETURN_VALUE(UInt32, kLatencyFrames);
        case kAudioDevicePropertySafetyOffset: RETURN_VALUE(UInt32, kSafetyFrames);
        case kAudioDevicePropertyIsHidden: RETURN_VALUE(UInt32, mic ? 0 : 1);
        case kAudioDevicePropertyZeroTimeStampPeriod: RETURN_VALUE(UInt32, kRingFrames);
        case kAudioDevicePropertyNominalSampleRate: RETURN_VALUE(Float64, kSampleRate);
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange r = { kSampleRate, kSampleRate };
            RETURN_VALUE(AudioValueRange, r);
        }
        case kAudioObjectPropertyControlList: *outDataSize = 0; return 0;
        case kAudioObjectPropertyOwnedObjects: case kAudioDevicePropertyStreams: {
            bool none = a->mSelector == kAudioDevicePropertyStreams
                && ((mic && a->mScope == kAudioObjectPropertyScopeOutput) || (!mic && a->mScope == kAudioObjectPropertyScopeInput));
            if (none || inDataSize < sizeof(AudioObjectID)) { *outDataSize = 0; return 0; }
            RETURN_VALUE(AudioObjectID, mic ? kObjectID_Mic_Stream : kObjectID_Feed_Stream);
        }
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            ((UInt32*)outData)[0] = 1; ((UInt32*)outData)[1] = 1;
            *outDataSize = 2 * sizeof(UInt32);
            return 0;
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            UInt32 size = (UInt32)offsetof(AudioChannelLayout, mChannelDescriptions) + kChannels * sizeof(AudioChannelDescription);
            if (inDataSize < size) return kAudioHardwareBadPropertySizeError;
            AudioChannelLayout* l = (AudioChannelLayout*)outData;
            memset(l, 0, size);
            l->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            l->mNumberChannelDescriptions = kChannels;
            l->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Mono;
            *outDataSize = size;
            return 0;
        }
        }
    } else if (IsStream(id)) {
        bool input = id == kObjectID_Mic_Stream;
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, input ? kObjectID_Mic : kObjectID_Feed);
        case kAudioObjectPropertyOwnedObjects: *outDataSize = 0; return 0;
        case kAudioStreamPropertyIsActive: {
            pthread_mutex_lock(&gStateMutex);
            UInt32 v = input ? gMicStreamActive : gFeedStreamActive;
            pthread_mutex_unlock(&gStateMutex);
            RETURN_VALUE(UInt32, v);
        }
        case kAudioStreamPropertyDirection: RETURN_VALUE(UInt32, input ? 1 : 0);
        case kAudioStreamPropertyTerminalType: RETURN_VALUE(UInt32, input ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker);
        case kAudioStreamPropertyStartingChannel: RETURN_VALUE(UInt32, 1);
        case kAudioStreamPropertyLatency: RETURN_VALUE(UInt32, kLatencyFrames);
        case kAudioStreamPropertyVirtualFormat: case kAudioStreamPropertyPhysicalFormat:
            RETURN_VALUE(AudioStreamBasicDescription, StreamFormat());
        case kAudioStreamPropertyAvailableVirtualFormats: case kAudioStreamPropertyAvailablePhysicalFormats: {
            AudioStreamRangedDescription r;
            r.mFormat = StreamFormat();
            r.mSampleRateRange.mMinimum = kSampleRate;
            r.mSampleRateRange.mMaximum = kSampleRate;
            RETURN_VALUE(AudioStreamRangedDescription, r);
        }
        }
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus DM_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a,
                                   UInt32 qSize, const void* q, UInt32 inDataSize, const void* inData) {
    (void)pid; (void)qSize; (void)q;
    if (inDriver != gDriverRef || !a || !inData) return kAudioHardwareIllegalOperationError;
    if (IsDevice(id) && a->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (inDataSize < sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        return *(const Float64*)inData == kSampleRate ? 0 : kAudioHardwareIllegalOperationError;
    }
    if (IsStream(id) && a->mSelector == kAudioStreamPropertyIsActive) {
        if (inDataSize < sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        pthread_mutex_lock(&gStateMutex);
        if (id == kObjectID_Mic_Stream) gMicStreamActive = *(const UInt32*)inData != 0;
        else gFeedStreamActive = *(const UInt32*)inData != 0;
        pthread_mutex_unlock(&gStateMutex);
        return 0;
    }
    if (IsStream(id) && (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (inDataSize < sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
        const AudioStreamBasicDescription* f = inData;
        return (f->mSampleRate == kSampleRate && f->mChannelsPerFrame == kChannels && f->mFormatID == kAudioFormatLinearPCM)
            ? 0 : kAudioDeviceUnsupportedFormatError;
    }
    return kAudioHardwareUnknownPropertyError;
}

// ───── IO ─────

static OSStatus DM_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID id, UInt32 client) {
    (void)client;
    if (inDriver != gDriverRef || !IsDevice(id)) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    gIOCount[id == kObjectID_Mic ? 0 : 1]++;
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

static OSStatus DM_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID id, UInt32 client) {
    (void)client;
    if (inDriver != gDriverRef || !IsDevice(id)) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    UInt32* n = &gIOCount[id == kObjectID_Mic ? 0 : 1];
    if (*n > 0) (*n)--;
    if (gIOCount[0] == 0 && gIOCount[1] == 0) memset(gRing, 0, sizeof gRing);
    pthread_mutex_unlock(&gStateMutex);
    return 0;
}

/// Both devices share one clock, anchored when the driver loaded, so a sample time means the same
/// moment on each: what the feed writes at time t is what the microphone reads at time t.
static OSStatus DM_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID id, UInt32 client,
                                    Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    (void)client;
    if (inDriver != gDriverRef || !IsDevice(id)) return kAudioHardwareBadObjectError;
    Float64 ticksPerRing = gHostTicksPerFrame * (Float64)kRingFrames;
    UInt64 periods = (UInt64)((Float64)(mach_absolute_time() - gAnchorHostTime) / ticksPerRing);
    *outSampleTime = (Float64)(periods * kRingFrames);
    *outHostTime = gAnchorHostTime + (UInt64)((Float64)periods * ticksPerRing);
    *outSeed = 1;
    return 0;
}

static OSStatus DM_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID id, UInt32 client, UInt32 op,
                                     Boolean* outWillDo, Boolean* outInPlace) {
    (void)client;
    if (inDriver != gDriverRef || !IsDevice(id)) return kAudioHardwareBadObjectError;
    *outWillDo = id == kObjectID_Mic ? op == kAudioServerPlugInIOOperationReadInput : op == kAudioServerPlugInIOOperationWriteMix;
    *outInPlace = true;
    return 0;
}

static OSStatus DM_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 c, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo* i) {
    (void)d; (void)id; (void)c; (void)op; (void)n; (void)i;
    return 0;
}

static OSStatus DM_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID id, AudioObjectID stream, UInt32 client,
                                 UInt32 op, UInt32 frames, const AudioServerPlugInIOCycleInfo* cycle, void* main, void* secondary) {
    (void)client; (void)secondary;
    if (inDriver != gDriverRef || !IsDevice(id) || !main) return kAudioHardwareBadObjectError;
    float* buf = main;
    if (op == kAudioServerPlugInIOOperationWriteMix && stream == kObjectID_Feed_Stream) {
        // What Duo Mac plays into the feed goes into the ring at its sample time…
        UInt64 t = (UInt64)cycle->mOutputTime.mSampleTime;
        for (UInt32 i = 0; i < frames; i++) gRing[(t + i) % kRingFrames] = buf[i];
    } else if (op == kAudioServerPlugInIOOperationReadInput && stream == kObjectID_Mic_Stream) {
        // …and comes back out as microphone input. Read samples are cleared, so the microphone is
        // silent (not a looping echo) when nothing is playing into it.
        UInt64 t = (UInt64)cycle->mInputTime.mSampleTime;
        for (UInt32 i = 0; i < frames; i++) {
            UInt32 k = (UInt32)((t + i) % kRingFrames);
            buf[i] = gRing[k];
            gRing[k] = 0;
        }
    }
    return 0;
}

static OSStatus DM_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 c, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo* i) {
    (void)d; (void)id; (void)c; (void)op; (void)n; (void)i;
    return 0;
}
