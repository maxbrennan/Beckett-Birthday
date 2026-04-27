/*
 * list_audio_devices.c
 *
 * Prints all audio output devices as a JSON array to stdout.
 *
 * Compile:
 *   cc list_audio_devices.c -framework CoreAudio -framework Foundation -o list_audio_devices
 *
 * Run:
 *   ./list_audio_devices
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <CoreAudio/CoreAudio.h>

static UInt32 count_output_channels(AudioObjectID device) {
    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyStreamConfiguration,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };
    if (!AudioObjectHasProperty(device, &addr)) return 0;
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &addr, 0, NULL, &size) != noErr) return 0;
    AudioBufferList *list = (AudioBufferList *)malloc(size);
    if (!list) return 0;
    UInt32 total = 0;
    if (AudioObjectGetPropertyData(device, &addr, 0, NULL, &size, list) == noErr) {
        for (UInt32 i = 0; i < list->mNumberBuffers; i++)
            total += list->mBuffers[i].mNumberChannels;
    }
    free(list);
    return total;
}

static int get_cfstring(AudioObjectID dev, AudioObjectPropertySelector sel,
                        AudioObjectPropertyScope scope, char *buf, UInt32 buf_size) {
    AudioObjectPropertyAddress addr = { sel, scope, kAudioObjectPropertyElementMain };
    if (!AudioObjectHasProperty(dev, &addr)) return 0;
    CFStringRef str = NULL;
    UInt32 size = sizeof(str);
    if (AudioObjectGetPropertyData(dev, &addr, 0, NULL, &size, &str) != noErr || !str) return 0;
    CFStringGetCString(str, buf, buf_size, kCFStringEncodingUTF8);
    CFRelease(str);
    return 1;
}

static int get_uint32(AudioObjectID dev, AudioObjectPropertySelector sel,
                      AudioObjectPropertyScope scope, UInt32 *out) {
    AudioObjectPropertyAddress addr = { sel, scope, kAudioObjectPropertyElementMain };
    if (!AudioObjectHasProperty(dev, &addr)) return 0;
    UInt32 size = sizeof(*out);
    return AudioObjectGetPropertyData(dev, &addr, 0, NULL, &size, out) == noErr;
}

static int get_float64(AudioObjectID dev, AudioObjectPropertySelector sel,
                       AudioObjectPropertyScope scope, Float64 *out) {
    AudioObjectPropertyAddress addr = { sel, scope, kAudioObjectPropertyElementMain };
    if (!AudioObjectHasProperty(dev, &addr)) return 0;
    UInt32 size = sizeof(*out);
    return AudioObjectGetPropertyData(dev, &addr, 0, NULL, &size, out) == noErr;
}

static void print_json_string(const char *s) {
    putchar('"');
    for (; *s; s++) {
        unsigned char c = (unsigned char)*s;
        if      (c == '"')  { fputs("\\\"", stdout); }
        else if (c == '\\') { fputs("\\\\", stdout); }
        else if (c == '\n') { fputs("\\n",  stdout); }
        else if (c == '\r') { fputs("\\r",  stdout); }
        else if (c == '\t') { fputs("\\t",  stdout); }
        else if (c < 0x20)  { printf("\\u%04x", c); }
        else                { putchar(c); }
    }
    putchar('"');
}

static const char *transport_name(UInt32 t, char *fallback, size_t fallback_size) {
    switch (t) {
        case kAudioDeviceTransportTypeBuiltIn:     return "Built-In";
        case kAudioDeviceTransportTypeAggregate:   return "Aggregate";
        case kAudioDeviceTransportTypeVirtual:     return "Virtual";
        case kAudioDeviceTransportTypePCI:         return "PCI";
        case kAudioDeviceTransportTypeUSB:         return "USB";
        case kAudioDeviceTransportTypeFireWire:    return "FireWire";
        case kAudioDeviceTransportTypeBluetooth:   return "Bluetooth";
        case kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth LE";
        case kAudioDeviceTransportTypeHDMI:        return "HDMI";
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort";
        case kAudioDeviceTransportTypeAirPlay:     return "AirPlay";
        case kAudioDeviceTransportTypeAVB:         return "AVB";
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt";
        default:
            snprintf(fallback, fallback_size, "Unknown (0x%08X)", t);
            return fallback;
    }
}

int main(void) {
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    UInt32 size = 0;
    OSStatus err = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &addr, 0, NULL, &size);
    if (err != noErr) { fprintf(stderr, "Failed to get device list size.\n"); return 1; }

    UInt32 device_count = size / sizeof(AudioObjectID);
    AudioObjectID *devices = (AudioObjectID *)malloc(size);
    if (!devices) { fprintf(stderr, "malloc failed.\n"); return 1; }

    err = AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr, 0, NULL, &size, devices);
    if (err != noErr) { fprintf(stderr, "Failed to get device list.\n"); free(devices); return 1; }

    printf("[\n");
    int first = 1;

    for (UInt32 i = 0; i < device_count; i++) {
        AudioObjectID dev = devices[i];
        UInt32 out_channels = count_output_channels(dev);
        if (out_channels == 0) continue;

        if (!first) printf(",\n");
        first = 0;

        printf("  {\n");
        printf("    \"id\": %u,\n", (unsigned)dev);

        char name[512] = "";
        get_cfstring(dev, kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal,
                     name, sizeof(name));
        printf("    \"name\": "); print_json_string(name); printf(",\n");

        char manufacturer[512] = "";
        int has_mfr = get_cfstring(dev, kAudioObjectPropertyManufacturer,
                                   kAudioObjectPropertyScopeGlobal,
                                   manufacturer, sizeof(manufacturer));
        printf("    \"manufacturer\": ");
        if (has_mfr) print_json_string(manufacturer); else printf("null");
        printf(",\n");

        char uid[512] = "";
        int has_uid = get_cfstring(dev, kAudioDevicePropertyDeviceUID,
                                   kAudioObjectPropertyScopeGlobal, uid, sizeof(uid));
        printf("    \"uid\": ");
        if (has_uid) print_json_string(uid); else printf("null");
        printf(",\n");

        char model_uid[512] = "";
        int has_muid = get_cfstring(dev, kAudioDevicePropertyModelUID,
                                    kAudioObjectPropertyScopeGlobal,
                                    model_uid, sizeof(model_uid));
        printf("    \"model_uid\": ");
        if (has_muid) print_json_string(model_uid); else printf("null");
        printf(",\n");

        {
            AudioObjectPropertyAddress ta = {
                kAudioDevicePropertyTransportType,
                kAudioObjectPropertyScopeGlobal,
                kAudioObjectPropertyElementMain
            };
            UInt32 transport = 0; UInt32 sz = sizeof(transport);
            printf("    \"transport\": ");
            if (AudioObjectGetPropertyData(dev, &ta, 0, NULL, &sz, &transport) == noErr) {
                char fallback[32];
                print_json_string(transport_name(transport, fallback, sizeof(fallback)));
            } else {
                printf("null");
            }
            printf(",\n");
        }

        printf("    \"output_channels\": %u,\n", (unsigned)out_channels);

        Float64 sample_rate = 0.0;
        int has_sr = get_float64(dev, kAudioDevicePropertyNominalSampleRate,
                                 kAudioObjectPropertyScopeGlobal, &sample_rate);
        printf("    \"sample_rate\": ");
        if (has_sr) printf("%.2f", sample_rate); else printf("null");
        printf(",\n");

        UInt32 latency = 0;
        int has_lat = get_uint32(dev, kAudioDevicePropertyLatency,
                                 kAudioDevicePropertyScopeOutput, &latency);
        printf("    \"output_latency_frames\": ");
        if (has_lat) printf("%u", (unsigned)latency); else printf("null");
        printf(",\n");

        UInt32 safety = 0;
        int has_saf = get_uint32(dev, kAudioDevicePropertySafetyOffset,
                                 kAudioDevicePropertyScopeOutput, &safety);
        printf("    \"safety_offset_frames\": ");
        if (has_saf) printf("%u", (unsigned)safety); else printf("null");
        printf(",\n");

        UInt32 buf_frames = 0;
        int has_bfs = get_uint32(dev, kAudioDevicePropertyBufferFrameSize,
                                 kAudioObjectPropertyScopeGlobal, &buf_frames);
        printf("    \"buffer_frame_size\": ");
        if (has_bfs) printf("%u", (unsigned)buf_frames); else printf("null");
        printf(",\n");

        UInt32 alive = 0;
        int has_alive = get_uint32(dev, kAudioDevicePropertyDeviceIsAlive,
                                   kAudioObjectPropertyScopeGlobal, &alive);
        printf("    \"is_alive\": ");
        if (has_alive) printf("%s", alive ? "true" : "false"); else printf("null");
        printf(",\n");

        UInt32 running = 0;
        int has_run = get_uint32(dev, kAudioDevicePropertyDeviceIsRunningSomewhere,
                                 kAudioObjectPropertyScopeGlobal, &running);
        printf("    \"is_running\": ");
        if (has_run) printf("%s", running ? "true" : "false"); else printf("null");
        printf(",\n");

        printf("  }");
    }

    printf("\n]\n");

    free(devices);
    return 0;
}
