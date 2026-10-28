#!/usr/bin/env python3
"""Build two isolated virtual audio cables. Never install or restart audio."""
from pathlib import Path
import hashlib, json, plistlib, re, subprocess, uuid

ROOT = Path(__file__).resolve().parent
VENDOR = ROOT / 'vendor/apple-null-audio'
OUT = ROOT / 'build'

def once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError('Apple sample patch anchor changed: ' + old[:60])
    return text.replace(old, new, 1)

source = (VENDOR / 'NullAudio.c').read_text()
base = once(source, '#include <stdint.h>', '#include <stdint.h>\n#include "cable-ring.h"\nstatic PBCableRing pbRing;')
base = re.sub(r'(gDevice_SampleRate\s*= )44100.0;', r'\g<1>48000.0;', base, count=1)
base = re.sub(r'(kDevice_RingBufferSize\s*= )16384;', r'\g<1>512;', base, count=1)
base = once(base, 'gDevice_AnchorHostTime = mach_absolute_time();', 'gDevice_AnchorHostTime = mach_absolute_time();\n\t\tPBCableReset(&pbRing);')
base = once(base, 'memset(ioMainBuffer, 0, inIOBufferFrameSize * 8);',
    'PBCableRead(&pbRing, (int64_t)inIOCycleInfo->mInputTime.mSampleTime, inIOBufferFrameSize, ioMainBuffer);\n'
    '\t}\n\telse if(inOperationID == kAudioServerPlugInIOOperationWriteMix)\n\t{\n'
    '\t\tPBCableWrite(&pbRing, (int64_t)inIOCycleInfo->mOutputTime.mSampleTime, inIOBufferFrameSize, ioMainBuffer);')
latency = '"NullAudio_GetDevicePropertyData: not enough space for the return value of kAudioDevicePropertyLatency for the device");\n\t\t\t*((UInt32*)outData) = 0;'
base = once(base, latency, latency[:-2] + '(inAddress->mScope == kAudioObjectPropertyScopeInput ? PB_CABLE_DELAY : 0);')
def device_case(name, body):
    global base
    definitions = list(re.finditer(r'^static[^\n]+NullAudio_' + name + r'\([^\n]+\)\n\{', base, re.M))
    if len(definitions) != 1: raise RuntimeError('Missing unique function definition: ' + name)
    start = definitions[0].start()
    switch = base.index('switch(inAddress->mSelector)', start)
    brace = base.index('{', switch) + 1
    base = base[:brace] + '\n\t\tcase 0x5042666C: /* PBfl: discard audio across recipient boundaries */\n' + body + '\n' + base[brace:]

device_case('HasDeviceProperty', '\t\t\ttheAnswer = true; break;')
device_case('IsDevicePropertySettable', '\t\t\t*outIsSettable = true; break;')
device_case('GetDevicePropertyDataSize', '\t\t\t*outDataSize = sizeof(CFPropertyListRef); break;')
device_case('GetDevicePropertyData', '\t\t\tif(inDataSize < sizeof(CFPropertyListRef)) return kAudioHardwareBadPropertySizeError;\n'
    '\t\t\t{ SInt64 epoch = (SInt64)atomic_load(&pbRing.epoch); *((CFPropertyListRef*)outData) = CFNumberCreate(NULL,kCFNumberSInt64Type,&epoch); }\n'
    '\t\t\t*outDataSize = sizeof(CFPropertyListRef); break;')
device_case('SetDevicePropertyData', '\t\t\tif(inDataSize != sizeof(CFPropertyListRef) || inData == NULL) return kAudioHardwareBadPropertySizeError;\n'
    '\t\t\t{ CFPropertyListRef payload=*((const CFPropertyListRef*)inData); SInt32 command=0;\n'
    '\t\t\tif(payload == NULL || CFGetTypeID(payload) != CFNumberGetTypeID() || !CFNumberGetValue((CFNumberRef)payload,kCFNumberSInt32Type,&command) || command != 1) return kAudioHardwareIllegalOperationError; }\n'
    '\t\t\tPBCableReset(&pbRing); *outNumberPropertiesChanged = 0; break;')
def custom_info(name, body):
    global base
    definition = re.search(r'^static[^\n]+NullAudio_' + name + r'\([^\n]+\)\n\{', base, re.M)
    switch = base.index('switch(inAddress->mSelector)', definition.start())
    brace = base.index('{', switch) + 1
    base = base[:brace] + '\n\t\tcase kAudioObjectPropertyCustomPropertyInfoList:\n' + body + '\n' + base[brace:]
custom_info('HasDeviceProperty', '\t\t\ttheAnswer = true; break;')
custom_info('IsDevicePropertySettable', '\t\t\t*outIsSettable = false; break;')
custom_info('GetDevicePropertyDataSize', '\t\t\t*outDataSize = sizeof(AudioServerPlugInCustomPropertyInfo); break;')
custom_info('GetDevicePropertyData', '\t\t\tif(inDataSize < sizeof(AudioServerPlugInCustomPropertyInfo)) return kAudioHardwareBadPropertySizeError;\n'
    '\t\t\t*((AudioServerPlugInCustomPropertyInfo*)outData) = (AudioServerPlugInCustomPropertyInfo){0x5042666C, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, 0};\n'
    '\t\t\t*outDataSize = sizeof(AudioServerPlugInCustomPropertyInfo); break;')
# The HAL host discovers the serialization of custom selectors from the
# plug-in's list; declaring it only on the device works in an interface harness
# but is not sufficient for the real client/server property boundary.
def in_function(name, old, new):
    global base
    definition = re.search(r'^static[^\n]+NullAudio_' + name + r'\([^\n]+\)\n\{', base, re.M)
    start = definition.start(); end = base.index('\n}\n', start) + 3
    base = base[:start] + once(base[start:end], old, new) + base[end:]
in_function('GetPlugInPropertyDataSize',
    'case kAudioObjectPropertyCustomPropertyInfoList:\n\t\t\t*outDataSize = sizeof(AudioServerPlugInCustomPropertyInfo);',
    'case kAudioObjectPropertyCustomPropertyInfoList:\n\t\t\t*outDataSize = 2 * sizeof(AudioServerPlugInCustomPropertyInfo);')
in_function('GetPlugInPropertyData',
    'inDataSize < sizeof(AudioServerPlugInCustomPropertyInfo)', 'inDataSize < 2 * sizeof(AudioServerPlugInCustomPropertyInfo)')
in_function('GetPlugInPropertyData',
    '*outDataSize = sizeof(AudioServerPlugInCustomPropertyInfo);',
    '((AudioServerPlugInCustomPropertyInfo*)outData)[1] = (AudioServerPlugInCustomPropertyInfo){0x5042666C, kAudioServerPlugInCustomPropertyDataTypeCFPropertyList, 0};\n\t\t\t*outDataSize = 2 * sizeof(AudioServerPlugInCustomPropertyInfo);')
manifest = {'source': 'https://developer.apple.com/documentation/coreaudio/creating-an-audio-server-driver-plug-in',
            'vendorSHA256': hashlib.sha256(source.encode()).hexdigest(), 'installed': False, 'drivers': []}
for role, name in [('Input', 'PhoneBridge Voice Input'), ('Output', 'PhoneBridge Voice Output')]:
    bundle_id = 'cn.andy.phonebridge.audio.' + role.lower()
    uid = bundle_id + '.device'
    code = base.replace('com.apple.audio.NullAudio', bundle_id).replace('NullAudioBox_UID', bundle_id + '.box')
    code = code.replace('NullAudioDevice_ModelUID', bundle_id + '.model').replace('NullAudioDevice_UID', uid)
    code = code.replace('CFSTR("DeviceName")', 'CFSTR("' + name + '")')
    code = code.replace('CFSTR("ManufacturerName")', 'CFSTR("PhoneBridge")').replace('CFSTR("Apple Inc.")', 'CFSTR("PhoneBridge")')
    code = code.replace('CFSTR("Null Box")', 'CFSTR("' + name + '")').replace('CFSTR("Null Model")', 'CFSTR("PhoneBridge Audio Cable")')
    bundle = OUT / ('PhoneBridgeVoice' + role + '.driver')
    mac = bundle / 'Contents/MacOS'; res = bundle / 'Contents/Resources'
    mac.mkdir(parents=True, exist_ok=True); res.mkdir(parents=True, exist_ok=True)
    generated = OUT / ('PhoneBridgeVoice' + role + '.c'); generated.write_text(code)
    factory = str(uuid.uuid5(uuid.NAMESPACE_DNS, bundle_id)).upper()
    info = {'CFBundleIdentifier': bundle_id, 'CFBundleExecutable': 'PhoneBridgeVoice' + role,
            'CFBundleName': name, 'CFBundlePackageType': 'BNDL', 'CFBundleVersion': '2',
            'CFBundleShortVersionString': '0.1.1',
            'CFPlugInFactories': {factory: 'NullAudio_Create'},
            'CFPlugInTypes': {'443ABAB8-E7B3-491A-B985-BEB9187030DB': [factory]}}
    (bundle / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
    (res / 'LICENSE.txt').write_bytes((VENDOR / 'LICENSE.txt').read_bytes())
    subprocess.run(['clang', '-std=c11', '-fblocks', '-O2', '-bundle', '-arch', 'arm64', '-arch', 'x86_64',
                    '-mmacosx-version-min=14.0', '-Wno-deprecated-declarations', '-I', str(ROOT),
                    str(generated), '-framework', 'CoreAudio', '-framework', 'CoreFoundation',
                    '-o', str(mac / ('PhoneBridgeVoice' + role))], check=True)
    subprocess.run(['codesign', '--force', '--sign', '-', str(bundle)], check=True)
    subprocess.run(['codesign', '--verify', '--strict', str(bundle)], check=True)
    manifest['drivers'].append({'bundle': str(bundle), 'uid': uid, 'name': name})
(OUT / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(json.dumps(manifest, indent=2))
