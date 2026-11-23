// Fallback implementations for Clang's Darwin availability runtime.
// The project targets iOS only; these weak definitions let newer Clang builds
// work with SDK/toolchain bundles that omit compiler-rt's OS-version helpers.
#import <Foundation/Foundation.h>

#include <stdint.h>

static int32_t WFOperatingSystemVersionAtLeast(uint32_t major, uint32_t minor,
                                               uint32_t patch) {
  NSOperatingSystemVersion current =
      [[NSProcessInfo processInfo] operatingSystemVersion];

  if ((uint32_t)current.majorVersion != major) {
    return (uint32_t)current.majorVersion > major;
  }
  if ((uint32_t)current.minorVersion != minor) {
    return (uint32_t)current.minorVersion > minor;
  }
  return (uint32_t)current.patchVersion >= patch;
}

extern "C" __attribute__((weak)) int32_t
__isOSVersionAtLeast(int32_t major, int32_t minor, int32_t patch) {
  return WFOperatingSystemVersionAtLeast((uint32_t)major, (uint32_t)minor,
                                         (uint32_t)patch);
}

extern "C" __attribute__((weak)) int32_t
__isPlatformVersionAtLeast(uint32_t platform, uint32_t major, uint32_t minor,
                           uint32_t patch) {
  // This library is injected only into the iOS YouTube app.
  (void)platform;
  return WFOperatingSystemVersionAtLeast(major, minor, patch);
}
